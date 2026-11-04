/*
 * libFuzzer harness for QEMU's Ethernet/IP packet parsing helpers (net/eth.c), the code the
 * e1000e/vmxnet3/virtio-net devices run on guest-supplied frames. The input is a raw frame,
 * split over several separately allocated iovec entries.
 */
#include "qemu/osdep.h"
#include "qemu/iov.h"
#include "net/eth.h"

#define MAX_FRAGS 4

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    struct iovec iov[MAX_FRAGS];
    int cnt;
    size_t pos, i;
    size_t l3off = 0, l4off = 0, l5off = 0;
    bool isip4, isip6, isudp, istcp;
    eth_ip6_hdr_info ip6;
    eth_ip4_hdr_info ip4;
    eth_l4_hdr_info l4;
    uint8_t ehdr[sizeof(struct eth_header) + 2 * sizeof(struct vlan_header)];
    uint16_t payload_off = 0, tci = 0;
    uint32_t cso;

    if (size < 1) {
        return 0;
    }
    cnt = 1 + (data[0] % MAX_FRAGS);
    pos = 1;
    for (i = 0; i < (size_t)cnt; i++) {
        size_t len;
        if (i == (size_t)cnt - 1) {
            len = size - pos;
        } else {
            len = pos < size ? data[pos++] % (size - pos + 1) : 0;
        }
        iov[i].iov_base = len ? malloc(len) : NULL;
        iov[i].iov_len = len;
        if (len) {
            memcpy(iov[i].iov_base, data + pos, len);
        }
        pos += len;
    }

    memset(&ip6, 0, sizeof(ip6));
    memset(&ip4, 0, sizeof(ip4));
    memset(&l4, 0, sizeof(l4));
    eth_get_protocols(iov, cnt, &isip4, &isip6, &isudp, &istcp,
                      &l3off, &l4off, &l5off, &ip6, &ip4, &l4);
    if (isip4) {
        eth_calc_ip4_pseudo_hdr_csum(&ip4.ip4_hdr, 20, &cso);
        eth_fix_ip4_checksum(&ip4.ip4_hdr, sizeof(ip4.ip4_hdr));
        eth_setup_ip4_fragmentation(ehdr, sizeof(struct eth_header),
                                    &ip4.ip4_hdr, sizeof(ip4.ip4_hdr),
                                    1480, 1480, true);
        eth_get_gso_type(ETH_P_IP, (uint8_t *)&ip4.ip4_hdr, ip4.ip4_hdr.ip_p);
    }
    if (isip6) {
        eth_calc_ip6_pseudo_hdr_csum(&ip6.ip6_hdr, 20, ip6.l4proto, &cso);
        eth_get_gso_type(ETH_P_IPV6, (uint8_t *)&ip6.ip6_hdr, ip6.l4proto);
    }

    eth_parse_ipv6_hdr(iov, cnt, eth_get_l2_hdr_length_iov(iov, cnt), &ip6);
    eth_parse_ipv6_hdr(iov, cnt, 0, &ip6);
    eth_strip_vlan(iov, cnt, 0, ehdr, &payload_off, &tci);
    eth_strip_vlan_ex(iov, cnt, 0, ETH_P_VLAN, ehdr, &payload_off, &tci);

    for (i = 0; i < (size_t)cnt; i++) {
        free(iov[i].iov_base);
    }
    return 0;
}
