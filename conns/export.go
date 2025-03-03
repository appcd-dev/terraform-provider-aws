package conns

import (
	"context"
	"iter"

	"github.com/hashicorp/terraform-plugin-sdk/v2/diag"
	"github.com/hashicorp/terraform-provider-aws/internal/conns"
)

type Config conns.Config

type AWSClient conns.AWSClient

func (c *Config) ConfigureProvider(ctx context.Context, client *AWSClient) (*AWSClient, diag.Diagnostics) {
	val, diag := (*conns.Config)(c).ConfigureProvider(ctx, (*conns.AWSClient)(client))
	return (*AWSClient)(val), diag
}

func (c *AWSClient) SetServicePackages(ctx context.Context, packages map[string]conns.ServicePackage) {
	(*conns.AWSClient)(c).SetServicePackages(ctx, packages)
}

func (c *AWSClient) ServicePackages(ctx context.Context) iter.Seq2[string, conns.ServicePackage] {
	return (*conns.AWSClient)(c).ServicePackages(ctx)
}
