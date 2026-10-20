export function sessionLink(base: string, id: string) {
  const url = new URL(base);
  url.hash = '';
  url.search = '';
  url.searchParams.set('session',id);
  return url.href;
}
