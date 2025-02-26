package conns

import (
	"context"
	"iter"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-provider-aws/internal/conns"
)

type Config conns.Config

type AWSClient conns.AWSClient

func (c *Config) ConfigureProvider(ctx context.Context) (*AWSClient, diag.Diagnostics) {
	return conns.Config(c).ConfigureProvider(ctx)
}

func (c *AWSClient) ServicePackages(context.Context) iter.Seq2[string, ServicePackage] {
	return conns.AWSClient(*c).ServicePackages(context.Background())
}
