/*
Copyright 2023 Chainguard, Inc.
SPDX-License-Identifier: Apache-2.0
*/

terraform {
  required_providers {
    cosign = {
      source = "chainguard-dev/cosign"
    }
    apko = {
      source = "chainguard-dev/apko"
    }
  }
}

data "apko_config" "this" {
  config_contents     = var.config
  extra_packages      = var.extra_packages
  default_annotations = var.default_annotations
}

resource "apko_build" "this" {
  repo   = var.target_repository
  config = data.apko_config.this.config
}

resource "cosign_sign" "signature" {
  image = apko_build.this.image_ref
}

locals {
  archs = toset(concat(data.apko_config.this.config.archs, length(data.apko_config.this.config.archs) > 1 ? ["index"] : []))
}

# Create SBOM attestations for each architecture.
resource "cosign_attest" "sboms" {
  for_each = local.archs

  image          = apko_build.this.sboms[each.key].digest
  predicate_type = apko_build.this.sboms[each.key].predicate_type
  predicate_file {
    path   = apko_build.this.sboms[each.key].predicate_path
    sha256 = apko_build.this.sboms[each.key].predicate_sha256
  }
}

# Create attestations for each architecture holding the "locked"
# configuration used to perform the build.
resource "cosign_attest" "apko-configuration" {
  for_each = local.archs

  image          = apko_build.this.sboms[each.key].digest
  predicate_type = "https://apko.dev/image-configuration"
  predicate      = jsonencode(data.apko_config.this.config)

  # Avoid racing with SBOMS to publish attestations.
  depends_on = [cosign_attest.sboms]
}

# Create attestations for each architecture holding the SLSA
# provenance of the build.
resource "cosign_attest" "slsa-provenance" {
  for_each = local.archs

  image          = apko_build.this.sboms[each.key].digest
  predicate_type = "https://slsa.dev/provenance/v1"
  predicate = jsonencode({
    buildDefinition = {
      buildType = "https://apko.dev/slsa-build-type@v1"
      # TODO(mattmoor): consider putting variables into `externalParameters`?
      # TODO(mattmoor): how do we fit into the shape of `resolvedDependencies`?

      # Use internal parameters to document the package resolution.
      internalParameters = {
        for k in data.apko_config.this.config.contents.packages : split("=", k)[0] => split("=", k)[1]
      }

      # TODO(mattmoor): Use an extension to encode the fully resolved apko configuration.
    }
    runDetails = {
      builder = {
        id = "https://github.com/chainguard-dev/terraform-provider-apko"
        version = {
          # TODO(mattmoor): How do we get the version of tf-apko?
        }
      }
      metadata = {
        invocationId = apko_build.this.id
      }
    }
  })

  # Avoid racing with apko-configuration to publish attestations.
  depends_on = [cosign_attest.apko-configuration]
}
