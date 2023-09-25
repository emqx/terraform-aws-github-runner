import { logger, setContext } from '@terraform-aws-github-runner/aws-powertools-util';
import { Context, SQSEvent } from 'aws-lambda';
import 'source-map-support/register';

import { PoolEvent, adjust } from './pool/pool';
import ScaleError from './scale-runners/ScaleError';
import { scaleDown } from './scale-runners/scale-down';
import { scaleUp } from './scale-runners/scale-up';
import { checkPending } from './scale-runners/check-pending';

export async function scaleUpHandler(event: SQSEvent, context: Context): Promise<void> {
  setContext(context, 'lambda.ts');
  logger.logEventIfEnabled(event);

  if (event.Records.length !== 1) {
    logger.warn('Event ignored, only one record at the time can be handled, ensure the lambda batch size is set to 1.');
    return new Promise((resolve) => resolve());
  }

  try {
    await scaleUp(event.Records[0].eventSource, JSON.parse(event.Records[0].body));
  } catch (e) {
    if (e instanceof ScaleError) {
      throw e;
    } else {
      logger.warn(`${JSON.stringify(e)}`);
    }
  }
}

export async function scaleDownHandler(event: unknown, context: Context): Promise<void> {
  setContext(context, 'lambda.ts');
  logger.logEventIfEnabled(event);

  try {
    await scaleDown();
  } catch (e) {
    logger.error(`${(e as Error).message}`, { error: e as Error });
  }
}

export async function checkPendingHandler(event: unknown, context: Context): Promise<void> {
  setContext(context, 'lambda.ts');
  logger.logEventIfEnabled(event);

  try {
    await checkPending();
  } catch (e) {
    logger.error(`${(e as Error).message}`, { error: e as Error });
  }
}

export async function adjustPool(event: PoolEvent, context: Context): Promise<void> {
  setContext(context, 'lambda.ts');
  logger.logEventIfEnabled(event);

  try {
    await adjust(event);
  } catch (e) {
    logger.error(`${(e as Error).message}`, { error: e as Error });
  }
}
