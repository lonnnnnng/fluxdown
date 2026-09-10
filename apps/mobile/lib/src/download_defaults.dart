// 作者: long
// 并发任务数控制队列槽位，线程数控制单任务分段请求；默认值集中维护，避免设置页、控制器和下载器各自漂移。
const defaultQueueConcurrency = 5;
const minQueueConcurrency = 1;
const maxQueueConcurrency = 30;

const defaultDownloadThreadCount = 16;
const minDownloadThreadCount = 1;
const maxDownloadThreadCount = 32;

const defaultRetryAttempts = 3;
const minRetryAttempts = 0;
const maxRetryAttempts = 10;
