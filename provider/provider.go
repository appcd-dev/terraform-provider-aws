// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

package provider

import (
	"context"

	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	"github.com/hashicorp/terraform-provider-aws/internal/provider/sdkv2"
)

// New returns an initialized Terraform Plugin SDK v2-style provider instance.
func New(ctx context.Context) (*schema.Provider, error) {
	return sdkv2.NewProvider(ctx)
}
