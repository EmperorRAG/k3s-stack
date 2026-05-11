# MTU Note: pfSense MSS Clamping Is a Prerequisite

The pfSense gateway at `10.0.40.1` has an OpenVPN-tunnelled WAN. The OpenVPN tunnel's MTU is below the standard 1500 bytes. Without intervention, TCP connections from VMs to the public internet will negotiate 1500-byte segments, those segments get fragmented (or dropped if DF is set), and the result is silently broken HTTPS:

- TLS handshakes hang after `ServerHello` with no error.
- Large downloads stall at 0 bytes.
- VS Code Remote-SSH server bootstrap fails partway through.
- `apt-get update` may sometimes succeed (small replies) but `apt-get install` of larger packages fails.

## The fix (already applied by the network admin)

**MSS clamping on pfSense**: in System → Advanced → Firewall & NAT, set "MSS clamping for VPN traffic" to `tunnel-MTU − 40` (e.g. if the OpenVPN tunnel MTU is 1300, set MSS to 1260). Alternatively, MSS clamping on the LAN firewall rules for traffic destined for the VPN.

Once MSS clamping is in place, every TCP connection from any LAN host has its segments sized correctly without anyone having to touch the host MTU. The VMs run with standard 1500 MTU and just work.

## What this means for this repo

Nothing — assuming MSS clamping stays in place on pfSense. The bootstrap script and the netplan it writes use the default MTU (1500). If MSS clamping is removed or breaks for any reason, the symptoms above will start appearing across the cluster.

## If you start seeing TLS hangs again

Check with the network admin that MSS clamping is still configured on pfSense for VPN traffic. As an emergency workaround you can drop every VM's `ens18` MTU to 1300 by editing the netplan config the bootstrap script writes (`/etc/netplan/01-static.yaml`), adding `mtu: 1300` under the `ens18` block, and running `sudo netplan apply`. But this is firefighting — the real fix lives on pfSense.
