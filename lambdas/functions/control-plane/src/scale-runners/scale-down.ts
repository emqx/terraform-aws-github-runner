import { Octokit } from '@octokit/rest';
import { createChildLogger } from '@terraform-aws-github-runner/aws-powertools-util';
import moment from 'moment';

import { createGithubAppAuth, createGithubInstallationAuth, createOctoClient } from '../gh-auth/gh-auth';
import { bootTimeExceeded, listEC2Runners, terminateRunner } from './../aws/runners';
import { RunnerInfo, RunnerList } from './../aws/runners.d';
import { GhRunners, githubCache } from './cache';
import { ScalingDownConfig, getEvictionStrategy, getIdleRunnerCount } from './scale-down-config';

const logger = createChildLogger('scale-down');

async function getOrCreateOctokit(runnerType: string, runnerOwner: string): Promise<Octokit> {
  const cachedOctokit = githubCache.clients.get(runnerOwner);

  if (cachedOctokit) {
    logger.debug(`[createGitHubClientForRunner] Cache hit for ${runnerOwner}`);
    return cachedOctokit;
  }

  logger.debug(`[createGitHubClientForRunner] Cache miss for ${runnerOwner}`);
  const ghesBaseUrl = process.env.GHES_URL;
  let ghesApiUrl = '';
  if (ghesBaseUrl) {
    ghesApiUrl = `${ghesBaseUrl}/api/v3`;
  }
  const ghAuthPre = await createGithubAppAuth(undefined, ghesApiUrl);
  const githubClientPre = await createOctoClient(ghAuthPre.token, ghesApiUrl);

  const installationId =
    runnerType === 'Org'
      ? (
          await githubClientPre.apps.getOrgInstallation({
            org: runnerOwner,
          })
        ).data.id
      : (
          await githubClientPre.apps.getRepoInstallation({
            owner: runnerOwner.split('/')[0],
            repo: runnerOwner.split('/')[1],
          })
        ).data.id;
  const ghAuth = await createGithubInstallationAuth(installationId, ghesApiUrl);
  const octokit = await createOctoClient(ghAuth.token, ghesApiUrl);
  githubCache.clients.set(runnerOwner, octokit);

  return octokit;
}

async function getGitHubRunnerBusyState(client: Octokit, ec2runner: RunnerInfo, runnerId: number): Promise<boolean> {
  const state =
    ec2runner.type === 'Org'
      ? await client.actions.getSelfHostedRunnerForOrg({
          runner_id: runnerId,
          org: ec2runner.owner,
        })
      : await client.actions.getSelfHostedRunnerForRepo({
          runner_id: runnerId,
          owner: ec2runner.owner.split('/')[0],
          repo: ec2runner.owner.split('/')[1],
        });

  logger.info(`Runner '${ec2runner.instanceId}' - GitHub Runner ID '${runnerId}' - Busy: ${state.data.busy}`);

  return state.data.busy;
}

async function listGitHubRunners(runnerType: string, runnerOwner: string): Promise<GhRunners> {
  const cachedRunners = githubCache.runners.get(runnerOwner);
  if (cachedRunners) {
    logger.debug(`[listGithubRunners] Cache hit for ${runnerOwner}`);
    return cachedRunners;
  }

  logger.debug(`[listGithubRunners] Cache miss for ${runnerOwner}`);
  const client = await getOrCreateOctokit(runnerType, runnerOwner);
  const runners =
    runnerType === 'Org'
      ? await client.paginate(client.actions.listSelfHostedRunnersForOrg, {
          org: runnerOwner,
          per_page: 100,
        })
      : await client.paginate(client.actions.listSelfHostedRunnersForRepo, {
          owner: runnerOwner.split('/')[0],
          repo: runnerOwner.split('/')[1],
          per_page: 100,
        });
  githubCache.runners.set(runnerOwner, runners);

  return runners;
}

function runnerMinimumTimeExceeded(runner: RunnerInfo): boolean {
  const minimumRunningTimeInMinutes = process.env.MINIMUM_RUNNING_TIME_IN_MINUTES;
  const launchTimePlusMinimum = moment(runner.launchTime).utc().add(minimumRunningTimeInMinutes, 'minutes');
  const now = moment(new Date()).utc();
  return launchTimePlusMinimum < now;
}

async function removeRunner(ec2runner: RunnerInfo, ghRunnerIds: number[]): Promise<void> {
  const githubAppClient = await getOrCreateOctokit(ec2runner.type, ec2runner.owner);
  try {
    const states = await Promise.all(
      ghRunnerIds.map(async (ghRunnerId) => {
        // Get busy state instead of using the output of listGitHubRunners(...) to minimize to race condition.
        return await getGitHubRunnerBusyState(githubAppClient, ec2runner, ghRunnerId);
      }),
    );

    if (states.every((busy) => busy === false)) {
      const statuses = await Promise.all(
        ghRunnerIds.map(async (ghRunnerId) => {
          return (
            ec2runner.type === 'Org'
              ? await githubAppClient.actions.deleteSelfHostedRunnerFromOrg({
                  runner_id: ghRunnerId,
                  org: ec2runner.owner,
                })
              : await githubAppClient.actions.deleteSelfHostedRunnerFromRepo({
                  runner_id: ghRunnerId,
                  owner: ec2runner.owner.split('/')[0],
                  repo: ec2runner.owner.split('/')[1],
                })
          ).status;
        }),
      );

      if (statuses.every((status) => status == 204)) {
        await terminateRunner(ec2runner.instanceId);
        logger.info(`AWS runner instance '${ec2runner.instanceId}' is terminated and GitHub runner is de-registered.`);
      } else {
        logger.error(`Failed to de-register GitHub runner: ${statuses}`);
      }
    } else {
      logger.info(`Runner '${ec2runner.instanceId}' cannot be de-registered, because it is still busy.`);
    }
  } catch (e) {
    logger.error(`Runner '${ec2runner.instanceId}' cannot be de-registered. Error: ${e}`, {
      error: e as Error,
    });
  }
}

async function evaluateAndRemoveRunners(
  ec2Runners: RunnerInfo[],
  scaleDownConfigs: ScalingDownConfig[],
): Promise<void> {
  let idleCounter = getIdleRunnerCount(scaleDownConfigs);
  const evictionStrategy = getEvictionStrategy(scaleDownConfigs);
  const ownerTags = new Set(ec2Runners.map((runner) => runner.owner));
  logger.debug(`Found: '${ownerTags.size}' unique owner tags: '${Array.from(ownerTags).join(', ')}'`);

  for (const ownerTag of ownerTags) {
    const ec2RunnersFiltered = ec2Runners
      .filter((runner) => runner.owner === ownerTag && runner.keep !== 'true')
      .sort(evictionStrategy === 'oldest_first' ? oldestFirstStrategy : newestFirstStrategy);
    logger.debug(`Found: '${ec2RunnersFiltered.length}' active GitHub runners with owner tag: '${ownerTag}'`);
    for (const ec2Runner of ec2RunnersFiltered) {
      logger.debug(`Evaluating runner ${ec2Runner}`);
      const ghRunners = await listGitHubRunners(ec2Runner.type, ec2Runner.owner);
      const ghRunnersFiltered = ghRunners.filter((runner: { name: string }) =>
        runner.name.endsWith(ec2Runner.instanceId),
      );
      if (ghRunnersFiltered.length) {
        if (runnerMinimumTimeExceeded(ec2Runner)) {
          if (idleCounter > 0) {
            idleCounter--;
            logger.info(`Runner '${ec2Runner.instanceId}' will be kept idle.`);
          } else {
            logger.info(`Runner '${ec2Runner.instanceId}' will be terminated.`);
            await removeRunner(
              ec2Runner,
              ghRunnersFiltered.map((runner: { id: number }) => runner.id),
            );
          }
        }
      } else {
        if (bootTimeExceeded(ec2Runner)) {
          logger.info(`Runner '${ec2Runner.instanceId}' is orphaned and will be removed.`);
          terminateOrphan(ec2Runner.instanceId);
        } else {
          logger.debug(`Runner ${ec2Runner.instanceId} has not yet booted.`);
        }
      }
    }
  }
}

async function terminateOrphan(instanceId: string): Promise<void> {
  try {
    await terminateRunner(instanceId);
  } catch (e) {
    logger.debug(`Orphan runner '${instanceId}' cannot be removed.`);
  }
}

function oldestFirstStrategy(a: RunnerInfo, b: RunnerInfo): number {
  if (a.launchTime === undefined) return 1;
  if (b.launchTime === undefined) return 1;
  if (a.launchTime < b.launchTime) return 1;
  if (a.launchTime > b.launchTime) return -1;
  return 0;
}

function newestFirstStrategy(a: RunnerInfo, b: RunnerInfo): number {
  return oldestFirstStrategy(a, b) * -1;
}

async function listRunners(environment: string) {
  return await listEC2Runners({
    environment,
  });
}

function filterRunners(ec2runners: RunnerList[]): RunnerInfo[] {
  return ec2runners.filter((ec2Runner) => ec2Runner.type) as RunnerInfo[];
}

async function deleteOfflineRunners(runnerType: string, runnerOwner: string, runnerLabels: string[]): Promise<void> {
  const ghRunners = await listGitHubRunners(runnerType, runnerOwner);
  const githubAppClient = await getOrCreateOctokit(runnerType, runnerOwner);
  await Promise.all(
    ghRunners.map(async (ghRunner) => {
      if (ghRunner.status !== 'offline') return null;
      if (runnerLabels.length > 0 && !ghRunner.labels.every((label) => runnerLabels.includes(label.name))) return null;
      logger.info(`Deleting runner ${ghRunner.name} with id ${ghRunner.id}`);
      return (
        runnerType === 'Org'
          ? await githubAppClient.actions.deleteSelfHostedRunnerFromOrg({
              runner_id: ghRunner.id,
              org: runnerOwner,
            })
          : await githubAppClient.actions.deleteSelfHostedRunnerFromRepo({
              runner_id: ghRunner.id,
              owner: runnerOwner.split('/')[0],
              repo: runnerOwner.split('/')[1],
            })
      ).status;
    }),
  );
}

export async function scaleDown(): Promise<void> {
  githubCache.reset();
  const scaleDownConfigs = JSON.parse(process.env.SCALE_DOWN_CONFIG) as [ScalingDownConfig];
  const environment = process.env.ENVIRONMENT;

  const ec2Runners = await listRunners(environment);
  const activeEc2RunnersCount = ec2Runners.length;
  logger.info(`Found: '${activeEc2RunnersCount}' active GitHub EC2 runner instances before clean-up.`);

  if (activeEc2RunnersCount !== 0) {
    const runners = filterRunners(ec2Runners);
    await evaluateAndRemoveRunners(runners, scaleDownConfigs);

    const activeEc2RunnersCountAfter = (await listRunners(environment)).length;
    logger.info(`Found: '${activeEc2RunnersCountAfter}' active GitHub EC2 runners instances after clean-up.`);
  } else {
    logger.debug(`No active runners found for environment: '${environment}'`);
  }

  if (process.env.RUNNER_TYPE && process.env.RUNNER_OWNER) {
    const runnerLabels = (process.env.RUNNER_LABELS || '').split(',');
    await deleteOfflineRunners(process.env.RUNNER_TYPE, process.env.RUNNER_OWNER, runnerLabels);
  }
}
