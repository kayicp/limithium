export function wait(ms, pubsub) {
  return new Promise(resolve => {
    const timer = setTimeout(() => {
      pubsub.off('refresh', onRefresh);
      resolve('timeout');
    }, ms);

    function onRefresh() {
      clearTimeout(timer);
      pubsub.off('refresh', onRefresh);
      resolve('refresh');
    }

    pubsub.on('refresh', onRefresh);
  });
}


export function retry(immediately, delay) {
  return immediately? 1000 : Math.min(delay * 2, 60000);
}
