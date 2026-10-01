// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

package conns

import (
	"context"
	"testing"

	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	"github.com/hashicorp/terraform-provider-aws/provider"
)

func TestConfigServicePackages(t *testing.T) {
	ctx := t.Context()
	awsProvider, err := provider.New(ctx)
	if err != nil {
		t.Fatal(err)
	}

	config := new(Config)
	servicePackages := config.ServicePackages(ctx, awsProvider)
	if len(servicePackages) == 0 {
		t.Fatal("ServicePackages returned no packages")
	}

	for name, servicePackage := range servicePackages {
		if name != servicePackage.ServicePackageName() {
			t.Errorf("service package key %q does not match name %q", name, servicePackage.ServicePackageName())
		}
	}
}

func TestConfigServicePackagesWithoutMeta(t *testing.T) {
	config := new(Config)
	servicePackages := config.ServicePackages(context.Background(), &schema.Provider{})
	if servicePackages != nil {
		t.Fatalf("ServicePackages = %v, want nil without configured provider metadata", servicePackages)
	}
}
