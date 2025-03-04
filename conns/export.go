package conns

import (
	"context"
	"iter"
	"maps"

	"github.com/hashicorp/terraform-plugin-sdk/v2/diag"
	"github.com/hashicorp/terraform-provider-aws/internal/conns"
)

type Config conns.Config

type AWSClient conns.AWSClient

type ServicePackage conns.ServicePackage

func (c *Config) ConfigureProvider(ctx context.Context, client *AWSClient) (*AWSClient, diag.Diagnostics) {
	val, diag := (*conns.Config)(c).ConfigureProvider(ctx, (*conns.AWSClient)(client))
	return (*AWSClient)(val), diag
}

func (c *AWSClient) SetServicePackages(ctx context.Context, input map[string]ServicePackage) {
	packages := make(map[string]conns.ServicePackage)
	for k, v := range input {
		packages[k] = conns.ServicePackage(v)
	}
	(*conns.AWSClient)(c).SetServicePackages(ctx, packages)
}

func (c *AWSClient) ServicePackages(ctx context.Context) iter.Seq2[string, ServicePackage] {
	servicePackage := (*conns.AWSClient)(c).ServicePackages(ctx)
	result := make(map[string]ServicePackage)
	servicePackage(func(k string, v conns.ServicePackage) bool {
		result[k] = v
		return true
	})
	return maps.All(result)
}
