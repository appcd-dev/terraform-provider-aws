// Copyright IBM Corp. 2014, 2026
// SPDX-License-Identifier: MPL-2.0

package glue

import (
	"testing"

	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
)

// Glue catalog tables and storage-descriptor columns use the same AWS Column
// shape. Keep partition_keys in sync with flattenColumn, which returns the
// parameters map when Glue includes it.
func TestResourceCatalogTablePartitionKeyParametersSchema(t *testing.T) {
	partitionKeys := ResourceCatalogTable().Schema["partition_keys"]
	if partitionKeys == nil {
		t.Fatal("partition_keys schema is missing")
	}

	block, ok := partitionKeys.Elem.(*schema.Resource)
	if !ok {
		t.Fatal("partition_keys must be a nested block")
	}

	parameters := block.Schema["parameters"]
	if parameters == nil {
		t.Fatal("partition_keys schema must accept Glue Column.Parameters")
	}
	if parameters.Type != schema.TypeMap {
		t.Errorf("parameters.Type = %v, want %v", parameters.Type, schema.TypeMap)
	}
	if !parameters.Optional {
		t.Error("parameters.Optional = false, want true")
	}

	value, ok := parameters.Elem.(*schema.Schema)
	if !ok {
		t.Fatal("parameters.Elem must be a schema.Schema")
	}
	if value.Type != schema.TypeString {
		t.Errorf("parameters.Elem.Type = %v, want %v", value.Type, schema.TypeString)
	}
}
