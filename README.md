# AVD Hybrid Environments – Deployment Scripts

PowerShell scripts to automate the deployment of **Azure Virtual Desktop (AVD) for Hybrid Environments** (Public Preview). Run AVD session hosts on-premises or on any non-Azure hypervisor using Azure Arc.

> **Public Preview:** Host pools must be configured as validation environments. Not recommended for production until General Availability.

---

## Overview

AVD Hybrid Environments extends AVD by using **Azure Arc** to bridge on-premises or non-Azure VMs into the AVD control plane. The session hosts run anywhere — your hypervisor, another cloud, a physical machine — while the host pool, workspace, and application group remain in Azure.

**Full walkthrough:** [https://bowker.cloud](https://bowker.cloud)

---

## Scripts

| Script | Purpose | Where to run |
|---|---|---|
| `Deploy-AVDHybrid-Greenfield.ps1` | Sets up all Azure infrastructure | Your admin machine |
| `Deploy-AVDHybrid-SessionHost.ps1` | Onboards each session host VM | On each session host VM |

---

## Supported Platforms

| | Virtual Machine | Physical Machine |
|---|---|---|
| Windows Server 2016–2025 | ✅ | ✅ |
| Windows 11 Enterprise (single-session) | ✅ | ❌ |
| Windows 11 Enterprise Multi-Session | ❌ | ❌ |

**Identity:** Entra joined, ADDS joined, or hybrid joined are all supported.

**Not supported:** Session hosts hosted on Azure, AWS, GCP, or Alibaba.

---

## Prerequisites

- Azure subscription with Owner or Contributor access
- PowerShell 5.1 or later (Windows PowerShell ISE or VS Code)
- Session host VM with outbound internet access to [AVD endpoints](https://learn.microsoft.com/en-us/azure/virtual-desktop/required-fqdn-endpoint) and [Azure Arc endpoints](https://learn.microsoft.com/en-us/azure/azure-arc/network-requirements-consolidated)
- Session host must be Entra joined, ADDS joined, or hybrid joined

---

## Quick Start

### Step 1 – Run the Greenfield script (admin machine)

1. Open `Deploy-AVDHybrid-Greenfield.ps1` in PowerShell ISE or VS Code
2. Update the variables in **Section 0**:
   ```powershell
   $TenantId        = "YOUR_TENANT_ID"
   $SubscriptionId  = "YOUR_SUBSCRIPTION_ID"
   $AdminAccount    = "YOUR_ADMIN_UPN"
   ```
3. Run section by section using **F8**
4. At the end, `AVD-SessionHost-Config.txt` is saved to your Desktop

### Step 2 – Run the Session Host script (on each VM)

1. Copy both `Deploy-AVDHybrid-SessionHost.ps1` and `AVD-SessionHost-Config.txt` into the same folder on the VM
2. Open in PowerShell ISE or VS Code — **Run as Administrator**
3. Run section by section using **F8**

### Step 3 – Assign users and connect

1. Add users to the `AVD-Users` group in **Entra ID → Groups → AVD-Users → Members**
2. Connect via [Windows App](https://windows.microsoft.com/en-gb/windows-app/download-windows-app) or [https://windows.cloud.microsoft](https://windows.cloud.microsoft)

---

## What the Greenfield Script Creates

| Resource | Name | Notes |
|---|---|---|
| Resource Group | `AVD-HostPool-RG` | Holds AVD resources |
| Resource Group | `AVD-ArcServers-RG` | Holds Arc-enabled session hosts |
| Host Pool | `AVD-HostPool` | Pooled, breadth-first, validation environment |
| Workspace | `AVD-Workspace` | Linked to app group |
| Application Group | `AVD-AppGroup` | Desktop app group |
| Entra Group | `AVD-Users` | Add users here to grant access |
| Service Principal | `AVD-ArcOnboarding-SP` | Used by session host script for Arc onboarding |

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `DomainJoinedCheck` failed | Ensure VM is Entra/ADDS/hybrid joined before installing Arc extension |
| Arc agent shows Disconnected | Re-run Section 3 — auto-detects and reconnects |
| Session host Unavailable | Check `SxSStackListenerCheck` — restart the VM |
| `MetaDataServiceCheck` failed | Semi-fatal in non-Azure environments — doesn't prevent connections |
| Registration token expired | Re-run Section 8 of Greenfield script, copy updated config file to VM |
| MSI installer fails (1603) | Run PowerShell ISE as Administrator |
| `BadRequest` on role assignments | Entra propagation delay — script includes 15s wait to mitigate |

---

## References

- [Deploy AVD Hybrid Environments](https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy-azure-virtual-desktop-hybrid)
- [Entra joined session hosts in AVD](https://learn.microsoft.com/en-us/azure/virtual-desktop/azure-ad-joined-session-hosts)
- [Azure Arc-enabled servers](https://learn.microsoft.com/en-us/azure/azure-arc/servers/)

---

## Author

**Dan Bowker** — [bowker.cloud](https://bowker.cloud)
