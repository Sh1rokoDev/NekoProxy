package main

import (
	"fmt"
	"os"

	"nekoproxy/runtime/rulesets"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: rulesets <geosite|geoip> <input.dat> <output-directory>")
		os.Exit(2)
	}
	if err := rulesets.Convert(os.Args[1], os.Args[2], os.Args[3]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
