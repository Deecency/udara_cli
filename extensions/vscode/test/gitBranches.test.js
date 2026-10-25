const test = require('node:test');
const assert = require('node:assert');
const { branchChoices } = require('../out/gitBranches');

test('offers other local branches, then remote-only ones', () => {
  const choices = branchChoices(
    'dev',
    ['dev', 'stable', 'feature/cards'],
    ['origin/HEAD', 'origin/dev', 'origin/stable', 'origin/release', 'upstream/hotfix'],
  );
  assert.deepStrictEqual(choices, [
    { ref: 'stable', kind: 'local' },
    { ref: 'feature/cards', kind: 'local' },
    { ref: 'origin/release', kind: 'remote' },
    { ref: 'upstream/hotfix', kind: 'remote' },
  ]);
});

test('never offers the checked-out branch, locally or on a remote', () => {
  assert.deepStrictEqual(branchChoices('stable', ['stable'], ['origin/stable']), []);
});

test('on a detached HEAD every branch is offered', () => {
  assert.deepStrictEqual(branchChoices(undefined, ['main'], ['origin/main', 'origin/x']), [
    { ref: 'main', kind: 'local' },
    { ref: 'origin/x', kind: 'remote' },
  ]);
});
