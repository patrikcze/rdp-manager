# Kerberos from a Mac

RDP Manager signs in with Kerberos through its FreeRDP engine and the MIT Kerberos library bundled in the app. Nothing on the Mac needs to be joined to the domain. Verified against a Windows Server 2025 domain on 2026-11-07 (see TESTING.md).

## What the Mac needs
1. **Name resolution for the domain.** The Mac must resolve the domain's names through a domain controller. Without a VPN or DHCP that already does this, add a resolver file (admin password needed; it affects only that domain):

   ```bash
   sudo mkdir -p /etc/resolver && echo "nameserver 10.0.0.10" | sudo tee /etc/resolver/example.com
   ```

   Replace `10.0.0.10` with a domain controller's address and `example.com` with the domain. Kerberos then finds the domain controllers through DNS (`_kerberos._tcp.example.com`), so no Kerberos configuration file is needed.
2. **Port 88 (TCP/UDP) to a domain controller.** Where the Mac can't reach one, set a KDC proxy URL in the connection (not verified live yet).
3. **A clock within 5 minutes of the domain's.**

## The connection
- **Host:** the server's DNS name, for example `server01.example.com`. Kerberos asks for a ticket for `TERMSRV/<host>`, and a domain has none for an IP address. With an IP address, "Kerberos only" is refused and "Kerberos (NTLM fallback)" signs in with NTLM.
- **User:** `user@example.com` with the Domain field empty, or the user name with Domain set to the full domain name (`EXAMPLE.COM`, not the short `EXAMPLE`). The domain becomes the Kerberos realm.
- **Authentication:** "Kerberos only" never signs in with NTLM. "Kerberos (NTLM fallback)" uses Kerberos where it can and NTLM otherwise.
- **Engine:** Automatic or FreeRDP. RDPKit has no Kerberos: with "Kerberos (NTLM fallback)" it signs in with NTLM, and "Kerberos only" refuses to connect on it.
- Enter the password in the app or save it in the Keychain. A ticket from macOS `kinit` isn't used, because the bundled Kerberos library can't read the macOS ticket cache.

An optional `~/Library/Preferences/edu.mit.Kerberos` (krb5.conf format) is read by the bundled library, for domains whose controllers can't be found through DNS.

## Checking which method signed in
The Inspector shows the configured method, not the one the server accepted. On the server, as an administrator:

```powershell
Get-WinEvent -LogName Security -MaxEvents 10 -FilterXPath "*[System[EventID=4624] and EventData[Data[@Name='TargetUserName']='user']]" |
  Select-Object TimeCreated,
    @{n='LogonType'; e={$_.Properties[8].Value}},
    @{n='Package';   e={$_.Properties[10].Value}},
    @{n='NTLM';      e={$_.Properties[14].Value}},
    @{n='From';      e={$_.Properties[18].Value}}
```

The row with LogonType 3 from the Mac's address is the sign-in: Package `Kerberos` with NTLM `-`, or Package `NTLM` with `NTLM V2`. The LogonType 10 rows ("Negotiate") are the desktop session that follows.
