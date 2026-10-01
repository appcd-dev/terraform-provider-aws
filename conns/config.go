// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

package conns

import (
	"context"
	"iter"

	"github.com/hashicorp/terraform-plugin-sdk/v2/diag"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	internalconns "github.com/hashicorp/terraform-provider-aws/internal/conns"
)

type Config internalconns.Config

func (c *Config) ConfigureProvider(ctx context.Context) (*AWSClient, diag.Diagnostics) {
	config := internalconns.Config(*c)
	return config.ConfigureProvider(ctx, &internalconns.AWSClient{})
}

func (c *Config) ServicePackages(ctx context.Context, provider *schema.Provider) map[string]ServicePackage {
	client, ok := provider.Meta().(*AWSClient)
	if !ok || client == nil {
		return nil
	}

	servicePackages := make(map[string]ServicePackage)
	next, stop := iter.Pull(client.ServicePackages(ctx))
	defer stop()
	for {
		servicePackage, valid := next()
		if !valid {
			break
		}
		servicePackages[servicePackage.ServicePackageName()] = servicePackage
	}

	return servicePackages
}
