"""Offline Listen on-device providers for yt-dlp.

This module is discovered by yt-dlp's plugin system (it lives under
``yt_dlp_plugins.extractor``) and registers two providers that close the
JavaScript-runtime gap on iOS, where there is no Deno/Node/QuickJS subprocess:

* ``OfflineListenJCP`` — a **JS-challenge provider** that solves YouTube's
  ``n``/``sig`` challenges by handing the real ``yt-dlp-ejs`` request payload to
  JavaScriptCore through the Swift bridge. Registering it (and reporting it
  available) is what makes yt-dlp choose the web player clients again instead of
  falling back to its JS-less client set.

* ``OfflineListenPTP`` — a **PO-token provider** that mints proof-of-origin
  tokens via a hidden ``WKWebView`` running BotGuard, again through the Swift
  bridge.

Both talk to Swift via callables the app installs on the ``builtins`` module
before extraction (``__ol_solve_js`` and ``__ol_mint_pot``). If a callable is
missing the provider reports itself unavailable, so yt-dlp simply behaves as it
did before — the whole integration is best-effort and never fatal.
"""

from __future__ import annotations

import builtins
import json

from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProvider,
    JsChallengeProviderError,
    JsChallengeProviderResponse,
    JsChallengeResponse,
    JsChallengeType,
    NChallengeOutput,
    SigChallengeOutput,
    register_preference as register_jsc_preference,
    register_provider as register_jsc_provider,
)
from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenContext,
    PoTokenProvider,
    PoTokenProviderError,
    PoTokenProviderRejectedRequest,
    PoTokenResponse,
    register_preference as register_pot_preference,
    register_provider as register_pot_provider,
)
from yt_dlp.extractor.youtube.pot.utils import get_webpo_content_binding

__all__ = ['OfflineListenJCP', 'OfflineListenPTP']

_SOLVE_JS = '__ol_solve_js'
_MINT_POT = '__ol_mint_pot'


def _bridge(name):
    """Return the Swift-installed callable, or None if the app hasn't wired it."""
    fn = getattr(builtins, name, None)
    return fn if callable(fn) else None


@register_jsc_provider
class OfflineListenJCP(JsChallengeProvider):
    PROVIDER_NAME = 'offlinelisten-jsc'
    PROVIDER_VERSION = '1.0.0'
    BUG_REPORT_LOCATION = 'the Offline Listen app'
    # We can solve both challenge kinds; JavaScriptCore runs the same ejs
    # scripts a Deno/QuickJS runner would.
    _SUPPORTED_TYPES = [JsChallengeType.N, JsChallengeType.SIG]

    def is_available(self) -> bool:
        return _bridge(_SOLVE_JS) is not None

    def _real_bulk_solve(self, requests):
        solve = _bridge(_SOLVE_JS)
        if solve is None:
            # Availability is re-checked here because is_available() and this
            # call aren't atomic; a missing bridge means "reject", so yt-dlp
            # tries the next provider (there is none) and degrades gracefully.
            for request in requests:
                yield JsChallengeProviderResponse(
                    request, None, JsChallengeProviderError('Swift JS bridge unavailable'))
            return

        # Group by player_url exactly like the built-in ejs provider: one Swift
        # solve call per distinct player resolves every challenge against it.
        grouped: dict[str, list] = {}
        for request in requests:
            grouped.setdefault(request.input.player_url, []).append(request)

        for player_url, group in grouped.items():
            video_id = next((r.video_id for r in group), None)
            try:
                player = self._get_player(video_id, player_url)
            except Exception as e:  # noqa: BLE001 — surface as a provider error per request
                for request in group:
                    yield JsChallengeProviderResponse(request, None, JsChallengeProviderError(str(e)))
                continue

            payload = json.dumps({
                'type': 'player',
                'player': player,
                'requests': [{
                    'type': request.type.value,
                    'challenges': request.input.challenges,
                } for request in group],
                'output_preprocessed': True,
            })

            self.logger.info('Solving JS challenges using JavaScriptCore (on-device)')
            try:
                stdout = solve(payload)
                output = json.loads(str(stdout))
            except Exception as e:  # noqa: BLE001
                for request in group:
                    yield JsChallengeProviderResponse(request, None, JsChallengeProviderError(str(e)))
                continue

            if output.get('type') == 'error':
                error = JsChallengeProviderError(output.get('error', 'unknown JSC error'))
                for request in group:
                    yield JsChallengeProviderResponse(request, None, error)
                continue

            responses = output.get('responses') or []
            for request, response_data in zip(group, responses):
                if response_data.get('type') == 'error':
                    yield JsChallengeProviderResponse(
                        request, None, JsChallengeProviderError(response_data.get('error', 'challenge failed')))
                    continue
                data = response_data.get('data') or {}
                out = (NChallengeOutput(data) if request.type is JsChallengeType.N
                       else SigChallengeOutput(data))
                yield JsChallengeProviderResponse(request, JsChallengeResponse(request.type, out))


@register_jsc_preference(OfflineListenJCP)
def _jsc_preference(provider, requests) -> int:
    # Above the ejs runners' scores (deno=1000 etc. only when a runtime exists);
    # on device we are the only available provider, so any positive value picks us.
    return 500


@register_pot_provider
class OfflineListenPTP(PoTokenProvider):
    PROVIDER_NAME = 'offlinelisten-pot'
    PROVIDER_VERSION = '1.0.0'
    BUG_REPORT_LOCATION = 'the Offline Listen app'
    _SUPPORTED_CONTEXTS = [PoTokenContext.GVS, PoTokenContext.PLAYER]
    # The WebPO clients whose tokens BotGuard-in-WKWebView can produce. We bind
    # gvs/player tokens the same way the web clients do.
    _SUPPORTED_CLIENTS = (
        'WEB', 'MWEB', 'TVHTML5', 'WEB_EMBEDDED_PLAYER',
        'WEB_CREATOR', 'WEB_REMIX', 'TVHTML5_SIMPLY',
        'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    )
    # All network egress is handled inside the Swift minter (URLSession +
    # WKWebView), not through yt-dlp's HTTP client, so no external-request
    # features are advertised.
    _SUPPORTED_EXTERNAL_REQUEST_FEATURES = None

    def is_available(self) -> bool:
        return _bridge(_MINT_POT) is not None

    def _real_request_pot(self, request) -> PoTokenResponse:
        mint = _bridge(_MINT_POT)
        if mint is None:
            raise PoTokenProviderRejectedRequest('Swift PO-token bridge unavailable')

        binding, _binding_type = get_webpo_content_binding(request)
        if not binding:
            raise PoTokenProviderRejectedRequest('No content binding available for this request')

        try:
            token = mint(binding, request.context.value, bool(request.bypass_cache))
        except Exception as e:  # noqa: BLE001
            raise PoTokenProviderError(f'BotGuard minting failed: {e}') from e

        if not token:
            # Best-effort: a None/empty token means minting is disabled or failed;
            # reject so yt-dlp proceeds without one (its own fallback logic).
            raise PoTokenProviderRejectedRequest('PO token not available (minting returned nothing)')

        return PoTokenResponse(po_token=str(token))


@register_pot_preference(OfflineListenPTP)
def _pot_preference(provider, request) -> int:
    return 500
