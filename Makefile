APP       ?= feather
VERSION   ?= $(shell git describe --tags --always 2>/dev/null || echo 0.1.0)
PKGROOT    = staging
DISTDIR    = dist
PLIST      = plist.txt

all: package

clean:
	rm -rf _build $(PKGROOT) $(DISTDIR) $(PLIST)

# Build Elixir release
release:
	MIX_ENV=prod mix deps.get --only prod
	MIX_ENV=prod mix compile
	MIX_ENV=prod mix release --overwrite

# Stage files into a fake rootfs (pkg staging dir)
stage: release
	rm -rf $(PKGROOT)
	# Create directory structure
	mkdir -p $(PKGROOT)/usr/local/feather
	mkdir -p $(PKGROOT)/usr/local/etc/rc.d

	# Copy the entire release (preserve permissions and structure)
	if [ -d "_build/prod/rel/$(APP)" ]; then \
		cp -R _build/prod/rel/$(APP)/* $(PKGROOT)/usr/local/feather/; \
	else \
		echo "❌ Release directory _build/prod/rel/$(APP) not found"; \
		exit 1; \
	fi

	# Ensure the binary is executable
	chmod +x $(PKGROOT)/usr/local/feather/bin/$(APP)

	# rc.d script
	if [ -f "rel/rc.d/$(APP)" ]; then \
		install -m 0755 rel/rc.d/$(APP) $(PKGROOT)/usr/local/etc/rc.d/$(APP); \
	else \
		echo "❌ RC script rel/rc.d/$(APP) not found"; \
		exit 1; \
	fi

	# pkg metadata: +PRE_INSTALL and +POST_INSTALL (executable)
	if [ -f "package/+PRE_INSTALL" ]; then \
		install -m 0755 package/+PRE_INSTALL $(PKGROOT)/+PRE_INSTALL; \
	else \
		echo "❌ Missing package/+PRE_INSTALL"; \
		exit 1; \
	fi
	if [ -f "package/+POST_INSTALL" ]; then \
		install -m 0755 package/+POST_INSTALL $(PKGROOT)/+POST_INSTALL; \
	else \
		echo "❌ Missing package/+POST_INSTALL"; \
		exit 1; \
	fi

	# +MANIFEST with version substituted
	if [ -f "package/+MANIFEST" ]; then \
		sed "s/__VERSION__/$(VERSION)/" package/+MANIFEST > $(PKGROOT)/+MANIFEST; \
	else \
		echo "❌ Missing package/+MANIFEST"; \
		exit 1; \
	fi

# Build the actual pkg using metadata-dir mode (-m)
package: stage
	mkdir -p $(DISTDIR)

	echo "== STAGING DIRECTORY CONTENTS (sample) =="
	find $(PKGROOT) -type f | head -20

	echo "== CHECK FOR BIN/$(APP) =="
	ls -l $(PKGROOT)/usr/local/feather/bin/$(APP) || echo "❌ Missing bin/$(APP)"

	# Generate PLIST *outside* staging and exclude metadata files
	( cd $(PKGROOT) && \
	  find . -type f -o -type l | \
	  grep -v '^\./\+MANIFEST$$' | \
	  grep -v '^\./\+COMPACT_MANIFEST$$' | \
	  grep -v '^\./\+PRE_INSTALL$$' | \
	  grep -v '^\./\+POST_INSTALL$$' | \
	  grep -v '^\./\+INSTALL$$' | \
	  sort \
	) > $(PLIST)

	echo "== PLIST CONTENTS (first 10) =="
	head -10 $(PLIST) || true

	echo "== METADATA FILES CHECK =="
	ls -la $(PKGROOT)/+* || echo "No metadata files found"

	# Create package with metadata-dir mode (this picks up +PRE_INSTALL/+POST_INSTALL automatically)
	pkg create -v -m $(PKGROOT) -r $(PKGROOT) -p $(PLIST) -o $(DISTDIR)

	@echo "✅ Built package(s) in $(DISTDIR):"; ls -lh $(DISTDIR)

install-local:
	pkg add $$(ls -1t $(DISTDIR)/*.pkg | head -n1)

debug-stage: stage
	echo "=== FULL STAGING DIRECTORY TREE ==="
	find $(PKGROOT) -ls
	echo "=== FILE SIZES ==="
	find $(PKGROOT) -type f -exec ls -lh {} \;
	echo "=== TOTAL SIZE ==="
	du -sh $(PKGROOT)

.PHONY: all clean release stage package install-local debug-stage
