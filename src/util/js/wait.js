export function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export function retry(immediately, delay) {
  return immediately? 1000 : Math.min(delay * 2, 60000);
}
