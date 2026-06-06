# Committee Node Changelog

## 0.2.0

- Added `Makefile` for deployment operations (`validate`, `render`, `install`, `doctor`, `upgrade`, `rollback`).
- Added CI workflow `.github/workflows/committee-node-validate.yml` to validate env schema and compose rendering.
- Pinned example DAS/validator images to Nitro digest:
  - `offchainlabs/nitro-node@sha256:597b913351e0efcd3452c9921d6f9b64e4e89de77dec2cabcc05f784d0f9b969`

## 0.1.0

- Initial committee node deployment scaffold.
- Added digest-ready `compose.yaml` for DAS + validator.
- Added env templates:
  - `env/das.env.example`
  - `env/validator.env.example`
- Added operational scripts:
  - `scripts/validate-env.sh`
  - `scripts/install.sh`
  - `scripts/doctor.sh`
  - `scripts/upgrade.sh`
  - `scripts/rollback.sh`
