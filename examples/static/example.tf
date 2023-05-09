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

variable "target_repository" {
  description = "The docker repo into which the image and attestations should be published."
}

provider "apko" {
  repositories = ["https://packages.wolfi.dev/os"]
  keyring      = ["https://packages.wolfi.dev/os/wolfi-signing.rsa.pub"]
  archs        = ["x86_64", "aarch64"]
  packages     = ["wolfi-baselayout"]
}

module "image" {
  source  = "../.."

  target_repository = var.target_repository
  config = file("${path.module}/static.yaml")
}

data "cosign_verify" "image-signature" {
  for_each = module.image.archs
  image    = module.image.arch_to_image[each.key]

  policy = jsonencode({
    apiVersion = "policy.sigstore.dev/v1beta1"
    kind       = "ClusterImagePolicy"
    metadata = {
      name = "signed"
    }
    spec = {
      images = [{ glob = "**" }]
      authorities = [{
        keyless = {
          url = "https://fulcio.sigstore.dev"
          identities = [{
            issuer  = "https://token.actions.githubusercontent.com"
            subject = "https://github.com/chainguard-dev/terraform-publisher-apko/.github/workflows/test.yaml@refs/heads/main"
          }]
        }
        ctlog = {
          url = "https://rekor.sigstore.dev"
        }
      }]
    }
  })
}

data "cosign_verify" "index-sbom" {
  for_each = module.image.archs
  image    = module.image.arch_to_image[each.key]

  policy = jsonencode({
    apiVersion = "policy.sigstore.dev/v1beta1"
    kind       = "ClusterImagePolicy"
    metadata = {
      name = "sbom-attestation"
    }
    spec = {
      images = [{ glob = "**" }]
      authorities = [{
        keyless = {
          url = "https://fulcio.sigstore.dev"
          identities = [{
            issuer  = "https://token.actions.githubusercontent.com"
            subject = "https://github.com/chainguard-dev/terraform-publisher-apko/.github/workflows/test.yaml@refs/heads/main"
          }]
        }
        ctlog = {
          url = "https://rekor.sigstore.dev"
        }
        attestations = [
          {
            name = "spdx-att"
            predicateType = "https://spdx.dev/Document"
            policy = {
              type = "cue"
              # TODO(mattmoor): Add more meaningful SBOM checks.
              data = "predicateType: \"https://spdx.dev/Document\""
            }
          },
        ]
      }]
    }
  })
}

output "image_ref" {
  value = module.image.image_ref
}