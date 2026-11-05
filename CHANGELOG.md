# Changelog

## [0.3.0](https://github.com/gondoi/multica-runtime-container/compare/v0.2.0...v0.3.0) (2026-11-05)


### Features

* **egress:** optional iron-proxy MITM-CA trust with fail-closed boot ([e02a546](https://github.com/gondoi/multica-runtime-container/commit/e02a54698605987082d49b6a4a6475aa1cfd41ec))
* **git:** gate SSH-&gt;HTTPS rewrite behind MULTICA_FORCE_HTTPS_GIT ([ab0356a](https://github.com/gondoi/multica-runtime-container/commit/ab0356a5733ec087d190ffed35ed8ac8e248404b))


### Bug Fixes

* **boot:** gate readiness on daemon status field, never crash on log stream ([a8f3788](https://github.com/gondoi/multica-runtime-container/commit/a8f3788dca2eeae29fdaf6288f0966b83e1f03f3))
* **boot:** warn when only MULTICA_AGENT_RUNTIME_NAME is set ([db74fbf](https://github.com/gondoi/multica-runtime-container/commit/db74fbfcb11b91c9d1ac6ac15827b5d6b1ce2f34))
* **git-auth:** force HTTPS for configured forges, fail-fast SSH timeout ([7a946af](https://github.com/gondoi/multica-runtime-container/commit/7a946af407963b97c1a8132130b3910861339ad0))

## [0.2.0](https://github.com/gondoi/multica-runtime-container/compare/v0.1.0...v0.2.0) (2026-11-04)


### Features

* **harness:** add Claude Code agent CLI harness ([19f5638](https://github.com/gondoi/multica-runtime-container/commit/19f5638a5b6f8b0cbe240f7164a4afdd27ca3c5d))
* **runtime:** name the runtime at startup via MULTICA_MACHINE_NAME ([c2b75f3](https://github.com/gondoi/multica-runtime-container/commit/c2b75f3c49e3794f965f3e1f7df554fbe674f95a))

## 0.1.0 (2026-11-04)


### Features

* **aws:** ConfigMap profiles, aws-sso pin, SSO cache on PVC ([f1186d3](https://github.com/gondoi/multica-runtime-container/commit/f1186d3538d1dc355cced0370000dc993cdfd8f8))
* **aws:** ConfigMap profiles, aws-sso pin, SSO cache on PVC ([b62c02c](https://github.com/gondoi/multica-runtime-container/commit/b62c02ceca4a03fd1a675feb4bbfbf1261c88ec1))
* **aws:** install AWS CLI v2 and document credential tiers ([7a492c7](https://github.com/gondoi/multica-runtime-container/commit/7a492c719909a56b46bd90b62d08277f6f4a1f32))
* **git:** App &gt; PAT &gt; password GitHub auth tiers with fallback ([d3ca9d2](https://github.com/gondoi/multica-runtime-container/commit/d3ca9d2377455298ecb9fe0495c48f846cd416a5))
* **git:** App &gt; PAT &gt; password GitHub auth tiers with fallback ([d9793ff](https://github.com/gondoi/multica-runtime-container/commit/d9793ff41bfa021e01b5b7da75a41320492eb9bd))
* **git:** GitHub App installation-token auth (no PAT) ([7583107](https://github.com/gondoi/multica-runtime-container/commit/75831078cc185d226c7c40e942bbabe3057dbda4))
* **git:** ship gh CLI wired to the auth tier ladder ([da7006e](https://github.com/gondoi/multica-runtime-container/commit/da7006e502f9cbd803374fb79914232ab990290c))
* **logs:** configurable daemon log level on container stdout ([2e50684](https://github.com/gondoi/multica-runtime-container/commit/2e50684b9f700bfe80ae73bdc4b40c0734d0a0f3))
* **logs:** configurable daemon log level on container stdout (MULTICA_LOG_LEVEL) ([1008e27](https://github.com/gondoi/multica-runtime-container/commit/1008e27775e9e3e91c50f2fe7c0f88f4f3760621))
* **release:** cut semver releases with release-please ([ec1a591](https://github.com/gondoi/multica-runtime-container/commit/ec1a59121b0675bbfd98533377c8799181c008d9))


### Bug Fixes

* **boot:** pin workspace after login (slug/name/UUID) ([c180a36](https://github.com/gondoi/multica-runtime-container/commit/c180a3662294547ba1702ddce4f5b7ca1c31a5bb))
* **git:** read App ID/installation ID from secret files ([6ade915](https://github.com/gondoi/multica-runtime-container/commit/6ade9154d125594a06ab59de33122bebbce4bf98))
* **release:** pin the initial release to 0.1.0 ([58da709](https://github.com/gondoi/multica-runtime-container/commit/58da709258acbe4ad4bdd7de17d066e8c06f1b92))
* **seam:** assert daemon start without requiring exec ([9dc20a4](https://github.com/gondoi/multica-runtime-container/commit/9dc20a4bd9d9283522a5d21902fc53801321a0a9))

## Changelog
