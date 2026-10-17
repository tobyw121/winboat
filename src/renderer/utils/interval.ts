/**
 * Sets an interval but also executes `func` immediately
 */
export function setIntervalImmediately(func: Function, interval: number): NodeJS.Timeout {
  func();
  // @ts-ignore Should be fine
  return setInterval(func, interval);
}
/** Skip ticks until the previous request finishes, including after a failure. */
export function skipWhileRunning(func: () => Promise<void>): () => Promise<void> {
  let running = false;
  return async () => {
    if (running) return;
    running = true;
    try { await func(); } finally { running = false; }
  };
}
