// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

package provider

import (
	"github.com/hashicorp/terraform-provider-aws/internal/provider"
)

type Provider = provider.Provider

type Resource = provider.Resource

// New returns a new, initialized Terraform Plugin SDK v2-style provider instance.
// The provider instance is fully configured once the `ConfigureContextFunc` has been called.
func New(ctx context.Context) (*schema.Provider, error) {
	return provider.New(ctx)
}