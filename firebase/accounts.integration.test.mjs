import test from 'node:test';
import assert from 'node:assert/strict';

// Deliberately emulator-only: no production project, inboxes, or credentials.
const project = 'demo-heymate-accounts';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST;
assert.match(authHost ?? '', /^(127\.0\.0\.1|localhost):9099$/);
assert.match(firestoreHost ?? '', /^(127\.0\.0\.1|localhost):8089$/);
const auth = `http://${authHost}/identitytoolkit.googleapis.com/v1/accounts:`;
const documents = `http://${firestoreHost}/v1/projects/${project}/databases/(default)/documents`;

async function request(url, body, token, method = body ? 'POST' : 'GET') {
  const response = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  return { status: response.status, body: await response.json() };
}

function commit(uid, subscribed, extra = {}) {
  return { writes: [{
    update: { name: `projects/${project}/databases/(default)/documents/accountPreferences/${uid}`,
      fields: { releaseEmails: { booleanValue: subscribed }, consentVersion: { integerValue: '1' }, ...extra } },
    updateTransforms: [{ fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' }],
  }] };
}

test('Firebase account verification and consent isolation', async t => {
  const email = `account-${Date.now()}@example.invalid`;
  const password = 'Emulator-only-test-91!';
  const signup = await request(`${auth}signUp?key=fake-key`, { email, password, returnSecureToken: true });
  assert.equal(signup.status, 200);
  const unverifiedToken = signup.body.idToken;
  let token = signup.body.idToken;
  const uid = signup.body.localId;
  const own = `${documents}/accountPreferences/${uid}`;

  await t.test('new account is unverified', async () => {
    const lookup = await request(`${auth}lookup?key=fake-key`, { idToken: token });
    assert.equal(lookup.body.users[0].emailVerified, false);
  });
  await t.test('anonymous cannot read or write', async () => {
    assert.equal((await request(own)).status, 403);
    assert.equal((await request(`${documents}:commit`, commit(uid, true))).status, 403);
  });
  await t.test('unverified user cannot read or record a subscription', async () => {
    assert.equal((await request(own, undefined, token)).status, 403);
    assert.equal((await request(`${documents}:commit`, commit(uid, true), token)).status, 403);
  });

  const sent = await request(`${auth}sendOobCode?key=fake-key`, { requestType: 'VERIFY_EMAIL', idToken: token });
  assert.equal(sent.status, 200);
  const codes = await request(`http://${authHost}/emulator/v1/projects/${project}/oobCodes`);
  const code = codes.body.oobCodes.find(c => c.email === email && c.requestType === 'VERIFY_EMAIL');
  assert.ok(code);
  const verified = await request(`${auth}update?key=fake-key`, { oobCode: code.oobCode });
  assert.equal(verified.status, 200);
  const refreshed = await fetch(`http://${authHost}/securetoken.googleapis.com/v1/token?key=fake-key`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: signup.body.refreshToken }),
  });
  assert.equal(refreshed.status, 200);
  token = (await refreshed.json()).id_token;

  await t.test('verified matching UID can save unchecked default with server timestamp', async () => {
    assert.equal((await request(`${documents}:commit`, commit(uid, false), token)).status, 200);
    const saved = await request(own, undefined, token);
    assert.equal(saved.status, 200);
    assert.equal(saved.body.fields.releaseEmails.booleanValue, false);
    assert.ok(saved.body.fields.updatedAt.timestampValue);
  });
  await t.test('verified user can explicitly subscribe and withdraw', async () => {
    assert.equal((await request(`${documents}:commit`, commit(uid, true), token)).status, 200);
    assert.equal((await request(own, undefined, token)).body.fields.releaseEmails.booleanValue, true);
    assert.equal((await request(`${documents}:commit`, commit(uid, false), token)).status, 200);
    assert.equal((await request(own, undefined, token)).body.fields.releaseEmails.booleanValue, false);
  });
  await t.test('cross-user reads and writes denied', async () => {
    assert.equal((await request(`${documents}/accountPreferences/someone-else`, undefined, token)).status, 403);
    assert.equal((await request(`${documents}:commit`, commit('someone-else', true), token)).status, 403);
  });
  await t.test('client cannot invent verified or admin fields', async () => {
    assert.equal((await request(`${documents}:commit`, commit(uid, true, { verified: { booleanValue: true } }), token)).status, 403);
  });
  await t.test('collection listing and deletion denied', async () => {
    assert.equal((await request(`${documents}/accountPreferences`, undefined, token)).status, 403);
    assert.equal((await request(own, undefined, token, 'DELETE')).status, 403);
  });
  await t.test('wrong password rejected', async () => {
    assert.equal((await request(`${auth}signInWithPassword?key=fake-key`, {
      email, password: 'wrong-password', returnSecureToken: true,
    })).status, 400);
  });

  await t.test('companion mailbox requires verified enrollment and enforces lifecycle', async () => {
    const enrollment = `${documents}/companionPilot/${uid}`;
    const group = `companionPilot/${uid}/pairs/pilot-pair/tasks`;
    const task = `${documents}/${group}/task-1`;
    const envelope = { bytesValue: Buffer.alloc(64, 1).toString('base64') };
    const requestFields = { version: { integerValue: '1' }, requestEnvelope: envelope };
    const write = (status, writer, fields = {}, creating = false) => {
      const timestamps = creating ? ['createdAt', 'updatedAt'] : ['updatedAt'];
      const update = { status: { stringValue: status }, ...fields };
      return request(`${documents}:commit`, { writes: [{
        update: { name: `projects/${project}/databases/(default)/documents/${group}/task-1`, fields: update },
        ...(!creating && { updateMask: { fieldPaths: Object.keys(update) } }),
        currentDocument: { exists: !creating },
        updateTransforms: timestamps.map(fieldPath => ({ fieldPath, setToServerValue: 'REQUEST_TIME' })),
      }] }, writer);
    };

    const optedIn = { fields: { enabled: { booleanValue: true } } };
    assert.equal((await write('queued', token, requestFields, true)).status, 403);
    assert.equal((await request(enrollment, optedIn, token, 'PATCH')).status, 403);
    assert.equal((await request(enrollment, optedIn, 'owner', 'PATCH')).status, 200);
    assert.equal((await request(task)).status, 403);
    assert.equal((await write('queued', unverifiedToken, requestFields, true)).status, 403);
    assert.equal((await write('queued', token, { ...requestFields, prompt: { stringValue: 'plaintext' } }, true)).status, 403);
    assert.equal((await write('queued', token, { ...requestFields, requestEnvelope: { stringValue: 'plaintext' } }, true)).status, 403);
    assert.equal((await write('queued', token, {
      ...requestFields, requestEnvelope: { bytesValue: Buffer.alloc(8193).toString('base64') },
    }, true)).status, 403);
    assert.equal((await write('queued', token, requestFields, true)).status, 200);
    assert.equal((await request(task, undefined, token)).body.fields.status.stringValue, 'queued');

    const otherUID = 'other-enrolled-pilot';
    assert.equal((await request(`${documents}/companionPilot/${otherUID}`, optedIn, 'owner', 'PATCH')).status, 200);
    assert.equal((await request(task.replace(uid, otherUID), undefined, token)).status, 403);
    const runQuery = limit => request(`${documents}/companionPilot/${uid}/pairs/pilot-pair:runQuery`, {
      structuredQuery: { from: [{ collectionId: 'tasks' }], limit },
    }, token);
    assert.equal((await runQuery(51)).status, 403);
    assert.equal((await runQuery()).status, 403);
    const query = await runQuery(50);
    assert.equal(query.status, 200);
    assert.ok(query.body.some(row => row.document?.name.endsWith('/task-1')));

    assert.equal((await write('completed', token, { resultEnvelope: envelope })).status, 403);
    assert.equal((await write('running', token, { requestEnvelope: { bytesValue: Buffer.alloc(64, 2).toString('base64') } })).status, 403);
    assert.equal((await write('running', token)).status, 200);
    assert.equal((await write('running', token)).status, 403);
    assert.equal((await request(task, undefined, token, 'DELETE')).status, 403);
    assert.equal((await write('completed', token)).status, 403);
    assert.equal((await write('completed', token, { resultEnvelope: envelope })).status, 200);
    assert.equal((await request(task, undefined, token)).body.fields.resultEnvelope.bytesValue, envelope.bytesValue);
    assert.equal((await write('queued', token)).status, 403);
    assert.equal((await request(enrollment, { fields: { enabled: { booleanValue: false } } }, 'owner', 'PATCH')).status, 200);
    assert.equal((await request(task, undefined, token)).status, 403);
    assert.equal((await request(enrollment, optedIn, 'owner', 'PATCH')).status, 200);
    assert.equal((await request(task, undefined, token, 'DELETE')).status, 200);
  });
});
