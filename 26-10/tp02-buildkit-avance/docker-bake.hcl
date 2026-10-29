variable "VERSION" {
  default = "dev"
}

variable "GIT_SHA" {
  default = "local"
}

variable "REGISTRY" {
  default = "localhost:5000"
}

group "default" {
  targets = ["api", "worker"]
}

# cible abstraite, jamais buildée seule
target "_common" {
  platforms = ["linux/amd64", "linux/arm64"]
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = GIT_SHA
    "org.opencontainers.image.vendor"   = "Shop SAS"
    "org.opencontainers.image.source"   = "https://github.com/Maksenoff/docker-ynov-tp"
  }
}

target "api" {
  inherits   = ["_common"]
  context    = "../tp01-optimisation-image/shopapi"
  dockerfile = "Dockerfile"
  target     = "runtime"
  args = {
    APP_VERSION = VERSION
    GIT_SHA     = GIT_SHA
  }
  tags       = ["${REGISTRY}/shopapi:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/cache:api"]
  cache-to   = ["type=registry,ref=${REGISTRY}/cache:api,mode=max"]
}

target "worker" {
  inherits   = ["_common"]
  context    = "shop-worker"
  dockerfile = "Dockerfile"
  target     = "runtime"
  args = {
    VERSION = VERSION
    GIT_SHA = GIT_SHA
  }
  secret     = ["id=pipconf,src=shop-worker/pip.conf"]
  tags       = ["${REGISTRY}/shop-worker:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/cache:worker"]
  cache-to   = ["type=registry,ref=${REGISTRY}/cache:worker,mode=max"]
}

# lance juste le stage test, rien n'est exporté
target "worker-test" {
  inherits  = ["worker"]
  target    = "test"
  platforms = ["linux/amd64"]
  tags      = []
  cache-to  = []
  output    = ["type=cacheonly"]
}
