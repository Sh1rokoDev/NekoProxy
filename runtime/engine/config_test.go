package engine

import "testing"

func TestValidateConfigUsesRuntimeOutboundRegistry(t *testing.T) {
	if err := ValidateConfig([]byte(`{"outbounds":[{"type":"direct","tag":"direct"}]}`)); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	if err := ValidateConfig([]byte(`{"outbounds":[{"type":"unknown-fixture","tag":"invalid"}]}`)); err == nil {
		t.Fatal("accepted an unknown outbound type")
	}
}
