// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

// Package conns exposes the AWS client and configuration helpers used by
// consumers embedding the Terraform AWS provider.
package conns

import internalconns "github.com/hashicorp/terraform-provider-aws/internal/conns"

type ServicePackage = internalconns.ServicePackage
