// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

package conns

import (
	"context"
	"iter"

	"github.com/hashicorp/terraform-plugin-sdk/v2/diag"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	"github.com/hashicorp/terraform-provider-aws/internal/conns"
)

type Config conns.Config

func (c *Config) ConfigureProvider(ctx context.Context) (*conns.AWSClient, diag.Diagnostics) {
	conf := conns.Config(*c)
	return conf.ConfigureProvider(ctx, &conns.AWSClient{})
}

func (c *Config) ServicePackages(ctx context.Context, provider *schema.Provider) map[string]conns.ServicePackage {
	var meta *conns.AWSClient
	v, ok := provider.Meta().(*conns.AWSClient)
	if ok {
		meta = v
	}

	it := meta.ServicePackages(ctx)
	servicePackages := make(map[string]conns.ServicePackage)
	next, stop := iter.Pull2(it)
	defer stop()
	for {
		key, value, valid := next()
		if !valid {
			break
		}
		servicePackages[key] = value
	}
	return servicePackages
}
