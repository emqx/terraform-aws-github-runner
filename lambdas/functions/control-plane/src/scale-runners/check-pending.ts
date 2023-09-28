import { SQS, SendMessageCommandInput } from '@aws-sdk/client-sqs';
import { createChildLogger } from '@terraform-aws-github-runner/aws-powertools-util';
import { createClient } from 'redis';

const logger = createChildLogger('check-pending');

export interface ActionRequestMessage {
  id: number;
  eventType: 'check_run' | 'workflow_job';
  repositoryName: string;
  repositoryOwner: string;
  installationId: number;
  queueId: string;
  queueFifo: boolean;
}

export async function checkPending(): Promise<void> {
  const redisUrl = process.env.RUNNER_REDIS_URL;
  if (!redisUrl) {
    logger.error('No redis url configured');
    return;
  }
  const actionRequestMaxWaitTime = Number(process.env.ACTION_REQUEST_MAX_WAIT_TIME || '300') * 1000;
  const actionRequestMaxRequeueCount = Number(process.env.ACTION_REQUEST_MAX_REQUEUE_COUNT || '5');

  logger.info(`Connecting to Redis at ${redisUrl}`);
  const redis = createClient({
    url: `redis://${redisUrl}:6379`,
  });
  redis.on('error', (err) => logger.error(`Cannot connect to redis on redis://${redisUrl}:6379: ${err}`));
  await redis.connect();
  for await (const key of redis.scanIterator({ MATCH: `workflow:*:ts`, COUNT: 1000, TYPE: 'string' })) {
    const [, id] = key.split(':');
    const ts = await redis.get(key);
    const currentTs = Date.now();
    logger.debug(`${key}=${ts}, currentTs=${currentTs}, MaxWaitTime=${actionRequestMaxWaitTime}`);
    if (actionRequestMaxWaitTime + Number(ts) > currentTs) {
      logger.debug(`Wait time in the queue for workflow id ${id} is less than ${actionRequestMaxWaitTime}, skip.`);
      continue;
    }
    const requeue_count = await redis.get(`workflow:${id}:requeue_count`);
    if (!requeue_count || Number(requeue_count) >= actionRequestMaxRequeueCount) {
      logger.warn(`Workflow id ${id} has been requeued ${requeue_count} times, delete the entry.`);
      await redis
        .multi()
        .del(`workflow:${id}:ts`)
        .del(`workflow:${id}:payload`)
        .del(`workflow:${id}:requeue_count`)
        .exec();
      continue;
    }
    const payload = await redis.get(`workflow:${id}:payload`);
    if (!payload) {
      logger.warn(`Workflow id ${id} has no payload, delete the entry.`);
      await redis.multi().del(`workflow:${id}:ts`).del(`workflow:${id}:requeue_count`).exec();
      continue;
    }
    const message: ActionRequestMessage = JSON.parse(payload) as ActionRequestMessage;
    await sendActionRequest(message);
    await redis.set(`workflow:${id}:requeue_count`, Number(requeue_count) + 1);
    logger.info(`Successfully re-queued job for workflow ${id} to the queue ${message.queueId}`);
  }
}

export const sendActionRequest = async (message: ActionRequestMessage): Promise<void> => {
  const sqs = new SQS({ region: process.env.AWS_REGION });

  const sqsMessage: SendMessageCommandInput = {
    QueueUrl: message.queueId,
    MessageBody: JSON.stringify(message),
  };

  logger.debug(`sending message to SQS: ${JSON.stringify(sqsMessage)}`);
  if (message.queueFifo) {
    sqsMessage.MessageGroupId = String(message.id);
  }

  await sqs.sendMessage(sqsMessage);
};
