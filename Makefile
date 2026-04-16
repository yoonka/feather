# Source-tree targets for development
.PHONY: build release clean

build:
	mix deps.get
	mix compile

release: build
	MIX_ENV=prod mix release
	cp dev/install.sh dev/feather.service dev/feather.rc _build/prod/rel/feather/
	cp -r config/examples _build/prod/rel/feather/examples
	chmod +x _build/prod/rel/feather/install.sh
	@echo ""
	@echo "Release ready in _build/prod/rel/feather/"
	@echo "Run: cd _build/prod/rel/feather && sudo ./install.sh"

clean:
	rm -rf _build deps
