'use strict';

const { handler } = require('../../src/lambda/example-function');

describe('example-function handler', () => {
  it('returns a 200 response with a JSON body', async () => {
    const event = {
      httpMethod: 'GET',
      path: '/hello',
    };

    const response = await handler(event);

    expect(response.statusCode).toBe(200);
    expect(response.headers['Content-Type']).toBe('application/json');

    const body = JSON.parse(response.body);
    expect(body.message).toBe('Hello from AWS!');
    expect(body.method).toBe('GET');
    expect(body.path).toBe('/hello');
  });

  it('returns a 500 response if handling the event throws', async () => {
    // event.httpMethod is read via optional chaining deeper in, but passing
    // something that breaks JSON.stringify (a circular reference) exercises
    // the catch branch.
    const circular = {};
    circular.self = circular;
    const event = { path: '/hello', requestContext: circular };

    const response = await handler(event);

    expect(response.statusCode).toBe(500);
    const body = JSON.parse(response.body);
    expect(body.message).toBe('Internal server error');
  });
});
