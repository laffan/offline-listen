// Offline Listen entry for building `botguard.js`.
//
// To regenerate the vendored bundle:
//   1. Clone bgutils-js v3.2.0 (https://github.com/LuanRT/BgUtils).
//   2. Drop this file in its repo root (the import below points at ./src).
//   3. `bun build ol-entry.ts --target=browser --format=iife --minify`
//   4. Prepend the provenance header (see the top of botguard.js) and save the
//      output as botguard.js in this directory.
//
// It bundles bgutils-js and exposes a single global that runs the whole
// PO-token flow inside the WKWebView. Because the WebView document sits in the
// youtube.com origin, the Create/GenerateIT fetches are same-origin — no CORS,
// and no native HTTP or challenge parsing needed on the Swift side.
import { BG, buildURL, GOOG_API_KEY } from './src/index.js';
import type { WebPoSignalOutput } from './src/index.js';

async function generatePot(requestKey: string, identifier: string): Promise<string> {
  // 1. Fetch + parse the BotGuard challenge (interpreter VM + program).
  const challengeResponse = await fetch(buildURL('Create', true), {
    method: 'POST',
    headers: {
      'content-type': 'application/json+protobuf',
      'x-goog-api-key': GOOG_API_KEY,
      'x-user-agent': 'grpc-web-javascript/0.1'
    },
    body: JSON.stringify([ requestKey ])
  });
  if (!challengeResponse.ok)
    throw new Error('Create failed: HTTP ' + challengeResponse.status);

  const bgChallenge = BG.Challenge.parseChallengeData(await challengeResponse.json());
  if (!bgChallenge)
    throw new Error('Could not parse challenge');

  const interpreterJavascript = bgChallenge.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (interpreterJavascript)
    new Function(interpreterJavascript)();
  else
    throw new Error('Could not load VM interpreter');

  // 2. Run the BotGuard program → BotGuard response.
  const botguard = await BG.BotGuardClient.create({
    globalName: bgChallenge.globalName,
    globalObj: globalThis,
    program: bgChallenge.program
  });
  const webPoSignalOutput: WebPoSignalOutput = [];
  const botguardResponse = await botguard.snapshot({ webPoSignalOutput });

  // 3. Exchange it for an integrity token.
  const integrityTokenResponse = await fetch(buildURL('GenerateIT', true), {
    method: 'POST',
    headers: {
      'content-type': 'application/json+protobuf',
      'x-goog-api-key': GOOG_API_KEY,
      'x-user-agent': 'grpc-web-javascript/0.1'
    },
    body: JSON.stringify([ requestKey, botguardResponse ])
  });
  const itJson = await integrityTokenResponse.json() as [string, number, number, string];
  if (typeof itJson[0] !== 'string')
    throw new Error('GenerateIT returned no integrity token');
  const estimatedTtlSecs = typeof itJson[1] === 'number' ? itJson[1] : undefined;

  // 4. Mint the final websafe PO token, bound to the content identifier
  //    (visitorData for gvs, videoId for player).
  const minter = await BG.WebPoMinter.create({ integrityToken: itJson[0] }, webPoSignalOutput);
  const poToken = await minter.mintAsWebsafeString(identifier);

  return JSON.stringify({ poToken, ttl: estimatedTtlSecs });
}

(globalThis as any).__ol_generate_pot = function (requestKey: string, identifier: string): Promise<string> {
  return generatePot(requestKey, identifier);
};
