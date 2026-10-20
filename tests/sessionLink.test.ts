import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sessionLink } from '../src/sessionLink.ts';

test('Session QR preserves GitHub Pages subpath and excludes admin and auth parameters', () => {
  assert.equal(sessionLink('https://example.github.io/lab-queue/?code=private&session=old#admin','new-session'),
    'https://example.github.io/lab-queue/?session=new-session');
});
