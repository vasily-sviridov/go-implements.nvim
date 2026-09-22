package fixture

import (
	"io"

	"example.com/implements-fixture/api"
)

type Local interface{ Run() }
type InterfaceAlias = Local
type DefinedInterface Local

type File struct{}

func (File) Read(p []byte) (int, error) { return 0, io.EOF }
func (*File) Close() error            { return nil }

type (
	Count int
	Names []string
	Other Count
	Empty struct{}
)

func (Count) Run() {}
func (Names) Run() {}
func (Other) Run() {}

var _ contracts.Runner = Count(0)
