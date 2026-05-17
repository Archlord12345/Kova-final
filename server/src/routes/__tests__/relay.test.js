const request = require('supertest');
const app = require('../../index');

describe('KOVA relay pairing and store-and-forward endpoints', () => {
  test('pairs devices and delivers each encrypted alert once', async () => {
    const code = '654321';

    await request(app)
      .post('/api/pair/register')
      .send({ code, parentDeviceId: 'parent-test' })
      .expect(201);

    const claim = await request(app)
      .post('/api/pair/claim')
      .send({ code, childDeviceId: 'child-test' })
      .expect(200);

    expect(claim.body.pairToken).toBeTruthy();

    const status = await request(app)
      .get(`/api/pair/status?code=${code}`)
      .expect(200);

    expect(status.body.paired).toBe(true);
    expect(status.body.pairToken).toBe(claim.body.pairToken);

    await request(app)
      .post('/api/alert/push')
      .set('Authorization', `Bearer ${claim.body.pairToken}`)
      .send({ encryptedData: 'encrypted-payload', iv: 'iv' })
      .expect(201);

    const firstPoll = await request(app)
      .get('/api/alert/poll')
      .set('Authorization', `Bearer ${claim.body.pairToken}`)
      .expect(200);

    expect(firstPoll.body.alerts).toHaveLength(1);
    expect(firstPoll.body.alerts[0].encryptedData).toBe('encrypted-payload');

    const secondPoll = await request(app)
      .get('/api/alert/poll')
      .set('Authorization', `Bearer ${claim.body.pairToken}`)
      .expect(200);

    expect(secondPoll.body.alerts).toHaveLength(0);
  });

  test('stores and returns the encrypted child profile for the paired child', async () => {
    const code = '765432';

    await request(app)
      .post('/api/pair/register')
      .send({ code, parentDeviceId: 'profile-parent' })
      .expect(201);

    const claim = await request(app)
      .post('/api/pair/claim')
      .send({ code, childDeviceId: 'profile-child' })
      .expect(200);

    await request(app)
      .post('/api/child/register')
      .set('Authorization', `Bearer ${claim.body.pairToken}`)
      .send({
        childId: 'child-profile-id',
        name: 'Mia',
        age: 9,
        encryptedData: 'encrypted-profile',
        iv: 'profile-iv',
      })
      .expect(200);

    const profile = await request(app)
      .get('/api/child/profile')
      .set('Authorization', `Bearer ${claim.body.pairToken}`)
      .expect(200);

    expect(profile.body.profile).toMatchObject({
      childId: 'child-profile-id',
      name: 'Mia',
      age: 9,
      encryptedData: 'encrypted-profile',
      iv: 'profile-iv',
    });
  });
});
