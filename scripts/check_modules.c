#include <stdio.h>
#include <sys/socket.h>
#include <linux/if_alg.h>
#include <errno.h>
#include <unistd.h>

int main() {
    // Intentamos crear un socket de la familia AF_ALG
    // 38 es el número para AF_ALG en la mayoría de arquitecturas
    int sock = socket(38, SOCK_SEQPACKET, 0);

    if (sock >= 0) {
        printf("[+] AF_ALG (algif) está disponible y cargado.\n");
        close(sock);
    } else {
        if (errno == EAFNOSUPPORT || errno == EPROTONOSUPPORT) {
            printf("[-] El módulo algif NO está cargado o no es soportado.\n");
        } else {
            perror("[-] Error inesperado al probar el socket");
        }
    }

    return 0;
}