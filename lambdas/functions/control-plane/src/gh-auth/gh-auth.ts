import { createAppAuth } from '@octokit/auth-app';
import {
  AppAuthOptions,
  AppAuthentication,
  AuthInterface,
  InstallationAccessTokenAuthentication,
  InstallationAuthOptions,
  StrategyOptions,
} from '@octokit/auth-app/dist-types/types';
import { Octokit as OctokitCore } from '@octokit/core';
import { OctokitOptions } from '@octokit/core/dist-types/types';
import { paginateRest } from '@octokit/plugin-paginate-rest';
import { restEndpointMethods } from '@octokit/plugin-rest-endpoint-methods';
import { retry } from '@octokit/plugin-retry';
import { throttling } from '@octokit/plugin-throttling';
import { request } from '@octokit/request';
import { createChildLogger } from '@terraform-aws-github-runner/aws-powertools-util';
import { getParameter } from '@terraform-aws-github-runner/aws-ssm-util';

export { RequestError } from '@octokit/request-error';
export type { RestEndpointMethodTypes } from '@octokit/plugin-rest-endpoint-methods';

export const ThrottledOctokit = OctokitCore.plugin(restEndpointMethods, paginateRest, retry, throttling).defaults({
  userAgent: `octokit.js/gh-auth-lambda`,
  throttle: {
    onRateLimit,
    onSecondaryRateLimit,
  },
});

export declare const Octokit: typeof ThrottledOctokit &
  import('@octokit/core/dist-types/types').Constructor<
    {
      paginate: import('@octokit/plugin-paginate-rest').PaginateInterface;
    } & import('@octokit/plugin-rest-endpoint-methods/dist-types/generated/method-types').RestEndpointMethods &
      import('@octokit/plugin-rest-endpoint-methods/dist-types/types').Api
  >;

const logger = createChildLogger('gh-auth');

export async function createOctoClient(token: string, ghesApiUrl = ''): Promise<Octokit> {
  const ocktokitOptions: OctokitOptions = {
    auth: token,
  };
  if (ghesApiUrl) {
    ocktokitOptions.baseUrl = ghesApiUrl;
    ocktokitOptions.previews = ['antiope'];
  }
  return new Octokit(ocktokitOptions);
}

export async function createGithubAppAuth(
  installationId: number | undefined,
  ghesApiUrl = '',
): Promise<AppAuthentication> {
  const auth = await createAuth(installationId, ghesApiUrl);
  const appAuthOptions: AppAuthOptions = { type: 'app' };
  return auth(appAuthOptions);
}

export async function createGithubInstallationAuth(
  installationId: number | undefined,
  ghesApiUrl = '',
): Promise<InstallationAccessTokenAuthentication> {
  const auth = await createAuth(installationId, ghesApiUrl);
  const installationAuthOptions: InstallationAuthOptions = { type: 'installation', installationId };
  return auth(installationAuthOptions);
}

async function createAuth(installationId: number | undefined, ghesApiUrl: string): Promise<AuthInterface> {
  const appId = parseInt(await getParameter(process.env.PARAMETER_GITHUB_APP_ID_NAME));
  let authOptions: StrategyOptions = {
    appId,
    privateKey: Buffer.from(
      await getParameter(process.env.PARAMETER_GITHUB_APP_KEY_BASE64_NAME),
      'base64',
      // replace literal \n characters with new lines to allow the key to be stored as a
      // single line variable. This logic should match how the GitHub Terraform provider
      // processes private keys to retain compatibility between the projects
    )
      .toString()
      .replace('/[\\n]/g', String.fromCharCode(10)),
  };
  if (installationId) authOptions = { ...authOptions, installationId };

  logger.debug(`GHES API URL: ${ghesApiUrl}`);
  if (ghesApiUrl) {
    authOptions.request = request.defaults({
      baseUrl: ghesApiUrl,
    });
  }
  return createAppAuth(authOptions);
}

function onRateLimit(retryAfter: number, options: any, _octokit: any) {
  logger.warn(`Request quota exhausted for request ${options.method} ${options.url}`);

  if (options.request.retryCount < 5) {
    // retry up to 5 times
    logger.info(`Retrying after ${retryAfter} seconds!`);
    return true;
  }
}

function onSecondaryRateLimit(retryAfter: number, options: any, _octokit: any) {
  logger.warn(`SecondaryRateLimit detected for request ${options.method} ${options.url}`);

  if (options.request.retryCount === 0) {
    // only retries once
    logger.info(`Retrying after ${retryAfter} seconds!`);
    return true;
  }
}

export type Octokit = InstanceType<typeof Octokit>;
