# Maintainer: Kernel-Dirichlet elliottdev93@gmail.com 
pkgname=smartswap
pkgver=r1.0.0
pkgrel=1
pkgdesc="dynamic global swappiness auto-adjuster for Arch servers with flexible system configuration"
arch=('x86_64')
url="https://github.com/Kernel-Dirichlet/smartswap"
license=('MIT')
depends=()
makedepends=()
source=('git+https://github.com/Kernel-Dirichlet/smartswap.git')
sha256sums=(SKIP)

build() {
    cd "$srcdir/$pkgname"
    make
}

package() {
    cd "$srcdir/$pkgname"
    make DESTDIR="$pkgdir/" install
}
