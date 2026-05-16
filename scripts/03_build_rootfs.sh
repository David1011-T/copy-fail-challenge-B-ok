#!/usr/bin/env bash
# scripts/03_build_rootfs.sh
# Construye initramfs con BusyBox estático
#
# Lecciones aprendidas (¡todas críticas!):
#   - scripts/config NO existe en BusyBox → usar sed
#   - olddefconfig NO existe en BusyBox → quitarlo
#   - CONFIG_TC=y rompe la compilación con kernels nuevos → poner =n
#   - CONFIG_STATIC=y es OBLIGATORIO o nada funciona
#   - make defconfig puede pedir entrada interactiva → usar yes "" pipe
#   - bzip2 debe estar instalado (manejado en Dockerfile)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUSYBOX_SRC="$WORKSPACE_ROOT/kernel/busybox"
INITRAMFS_DIR="$WORKSPACE_ROOT/kernel/initramfs"
BUILD_DIR="$WORKSPACE_ROOT/kernel/build"
JOBS="$(nproc)"

STUDENT_ID="${STUDENT_ID:-$(git -C "$WORKSPACE_ROOT" config user.name 2>/dev/null \
                | tr ' ' '-' | tr -cd '[:alnum:]-' | head -c 20)}"
STUDENT_ID="${STUDENT_ID:-unnamed}"

CYAN='\033[1;36m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${CYAN}[1/5] Clonando BusyBox...${NC}"
if [ ! -d "$BUSYBOX_SRC" ]; then
  git clone --depth 1 https://git.busybox.net/busybox "$BUSYBOX_SRC"
fi

cd "$BUSYBOX_SRC"

echo -e "${CYAN}[2/5] Configurando BusyBox (static + sin TC)...${NC}"
# yes "" alimenta enter a posibles preguntas interactivas de defconfig
#yes "" | make defconfig >/dev/null 2>&1
make defconfig

# CRÍTICO: editar el .config con sed (BusyBox NO tiene scripts/config)
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
grep -q "^CONFIG_STATIC=y" .config || echo "CONFIG_STATIC=y" >> .config

# CONFIG_TC rompe la compilación con kernels nuevos (error en networking/tc.c)
sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
sed -i 's/^CONFIG_FEATURE_TC_INGRESS=y/CONFIG_FEATURE_TC_INGRESS=n/' .config

# NOTA: BusyBox NO tiene "make olddefconfig", se compila directo

echo -e "${CYAN}[3/5] Compilando BusyBox estático (~3-5 min)...${NC}"
make -j"$JOBS" 2>&1 | tail -3

# Verificar que quedó estático
if ! file busybox | grep -q "statically linked"; then
  echo -e "${YELLOW}⚠ BusyBox NO quedó estático. Verificando .config...${NC}"
  grep STATIC .config
  exit 1
fi
echo -e "${GREEN}  ✓ BusyBox compilado estáticamente${NC}"

echo -e "${CYAN}[4/5] Instalando BusyBox en initramfs y armando estructura...${NC}"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"
make CONFIG_PREFIX="$INITRAMFS_DIR" install 2>&1 | tail -3

# Estructura mínima
mkdir -p "$INITRAMFS_DIR"/{proc,sys,dev,tmp,etc,root,home/student,run}

# Usuario student (sin privilegios) y root
cat > "$INITRAMFS_DIR/etc/passwd" << 'PASSWD'
root:x:0:0:root:/root:/bin/sh
student:x:1001:1001::/home/student:/bin/sh
PASSWD

cat > "$INITRAMFS_DIR/etc/group" << 'GROUP'
root:x:0:
student:x:1001:
GROUP

# Script init (requiere BINFMT_SCRIPT en el kernel, ya habilitado)
cat > "$INITRAMFS_DIR/init" << INITEOF
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || /bin/busybox mdev -s
mount -t tmpfs none /tmp

# Cargar módulos crypto vulnerables si están como módulos
/bin/busybox modprobe algif_aead 2>/dev/null || true
/bin/busybox modprobe authencesn 2>/dev/null || true

# Hostname con el STUDENT_ID embebido (anti-copia)
hostname "copy-fail-${STUDENT_ID}"

echo ""
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║  Kernel vulnerable: \$(uname -r)               ║"
echo "  ║  CVE-2026-31431 Copy Fail Lab                ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo ""

# Login como student (sin privilegios) para simular el escenario LPE

exec setsid cttyhack sh

INITEOF
chmod +x "$INITRAMFS_DIR/init"

echo -e "${CYAN}[4.2/5] Copiando Biblioteca Estándar Completa para Python...${NC}"

PY_VER="3.12" 
mkdir -p "$INITRAMFS_DIR/usr/lib/python${PY_VER}"
mkdir -p "$INITRAMFS_DIR/usr/lib/python${PY_VER}/lib-dynload"

HOST_PY_LIB="/usr/lib/python${PY_VER}"
HOST_DYNLOAD="/usr/lib/python${PY_VER}/lib-dynload"

# 1. Copiar paquetes de soporte estructurales completos
if [ -d "$HOST_PY_LIB/encodings" ]; then
    cp -r "$HOST_PY_LIB/encodings" "$INITRAMFS_DIR/usr/lib/python${PY_VER}/"
fi
if [ -d "$HOST_PY_LIB/collections" ]; then
    cp -r "$HOST_PY_LIB/collections" "$INITRAMFS_DIR/usr/lib/python${PY_VER}/"
fi

# 2. Archivos .py individuales indispensables (Estructura de Sockets, Tipos y Enumeradores)
CORE_MODULES=(
    "os.py" "socket.py" "selectors.py" "io.py" "abc.py" "stat.py" "codecs.py" 
    "reprlib.py" "_collections_abc.py" "keyword.py" "operator.py" "enum.py" 
    "types.py" "functools.py" "struct.py" "copy.py"
)

for mod in "${CORE_MODULES[@]}"; do
    if [ -f "$HOST_PY_LIB/$mod" ]; then
        cp "$HOST_PY_LIB/$mod" "$INITRAMFS_DIR/usr/lib/python${PY_VER}/"
    fi
done

# 3. Extensiones binarias en C (.so) necesarias para el bajo nivel de los módulos anteriores
if [ -d "$HOST_DYNLOAD" ]; then
    CORE_EXTENSIONS=("_socket" "zlib" "select" "_functools" "_struct")
    for ext in "${CORE_EXTENSIONS[@]}"; do
        cp $HOST_DYNLOAD/${ext}.cpython-*.so "$INITRAMFS_DIR/usr/lib/python${PY_VER}/lib-dynload/" 2>/dev/null || true
    done
fi

echo -e "${GREEN}  ✓ Biblioteca estándar de Python y extensiones nativas sincronizadas.${NC}"

HOME_DIR="$INITRAMFS_DIR/home/student"

echo -e "${CYAN}[4.3/5] Incluyendo script de Python copy_fail_exp.py en el directorio home...${NC}"

# 2. Verificar si el archivo existe en el host antes de copiarlo
if [ -f "$SCRIPT_DIR/copy_fail_exp.py" ]; then
    # Asegurar que la carpeta personal exista en el rootfs
    mkdir -p "$HOME_DIR"

    # 3. Copiarlo a la carpeta personal definida
    cp "$SCRIPT_DIR/copy_fail_exp.py" "$HOME_DIR/"
    
    # 4. Darle permisos de ejecución en su nueva ubicación
    chmod +x "$HOME_DIR/copy_fail_exp.py"
    echo -e "${GREEN}  ✓ Script copy_fail_exp.py copiado a la carpeta personal del usuario.${NC}"
else
    echo -e "${YELLOW}  ⚠ No se encontró copy_fail_exp.py en $SCRIPT_DIR. Omitiendo...${NC}"
fi

echo -e "${CYAN}[4.4/5] Copiando el binario de Python y dependencias compartidas...${NC}"

# 1. Crear directorios para los binarios y librerías del sistema
mkdir -p "$INITRAMFS_DIR/usr/bin"
mkdir -p "$INITRAMFS_DIR/lib64"

# 2. Copiar el binario ejecutable de Python desde el Host
cp /usr/bin/python3 "$INITRAMFS_DIR/usr/bin/"
ln -sf /usr/bin/python3 "$INITRAMFS_DIR/bin/python3"

# 3. Copiar el cargador dinámico esencial (evita que el kernel diga "not found")
if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
    cp /lib64/ld-linux-x86-64.so.2 "$INITRAMFS_DIR/lib64/"
fi

# 4. Bucle inteligente para copiar todas las librerías (.so) que requiere Python
for lib in $(ldd /usr/bin/python3 | grep -o '/lib.*\.[0-9]'); do
    # Crear la estructura de carpetas correspondiente en el initramfs
    mkdir -p "$INITRAMFS_DIR$(dirname "$lib")"
    # Copiar la librería (.so) real
    cp "$lib" "$INITRAMFS_DIR$lib"
done

echo -e "${GREEN}  ✓ Intérprete binario de Python 3 inyectado con éxito.${NC}"

echo -e "${CYAN}[4.5/5] Compilando e incluyendo herramientas personalizadas...${NC}"
# 1. Compilar check_modules.c de forma estática
# Asumimos que check_modules.c está en la carpeta 'scripts'
gcc -static "$SCRIPT_DIR/check_modules.c" -o "$INITRAMFS_DIR/bin/check_modules"

# 2. Darle permisos de ejecución dentro del sistema virtual
chmod +x "$INITRAMFS_DIR/bin/check_modules"

echo -e "${GREEN}  ✓ Herramienta check_modules incluida en /bin/${NC}"

echo -e "${CYAN}[4.6/5] Asegurando la existencia de /usr/bin/su...${NC}"

# 1. Crear el directorio contenedor dentro del initramfs por si no existe
mkdir -p "$INITRAMFS_DIR/usr/bin"

# 2. Crear el enlace simbólico apuntando al BusyBox del sistema operativo virtual
# Esto hace que cuando se llame a /usr/bin/su, BusyBox ejecute su función de cambio de usuario
ln -sf /bin/busybox "$INITRAMFS_DIR/usr/bin/su"

echo -e "${GREEN}  ✓ Enlace ejecutable /usr/bin/su creado correctamente.${NC}"

echo -e "${CYAN}[5/5] Empaquetando initramfs...${NC}"
cd "$INITRAMFS_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip > "$BUILD_DIR/initramfs.cpio.gz"

SIZE=$(du -sh "$BUILD_DIR/initramfs.cpio.gz" | cut -f1)
echo -e "${GREEN}✓ initramfs listo (${SIZE}) en: $BUILD_DIR/initramfs.cpio.gz${NC}"
echo -e "${GREEN}  STUDENT_ID: ${STUDENT_ID}${NC}"
