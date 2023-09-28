import { Octokit } from '../gh-auth/gh-auth';

export type UnboxPromise<T> = T extends Promise<infer U> ? U : T;

export type GhRunners = UnboxPromise<ReturnType<Octokit['actions']['listSelfHostedRunnersForRepo']>>['data']['runners'];

export class githubCache {
  static clients: Map<string, Octokit> = new Map();
  static runners: Map<string, GhRunners> = new Map();

  public static reset(): void {
    githubCache.clients.clear();
    githubCache.runners.clear();
  }
}
