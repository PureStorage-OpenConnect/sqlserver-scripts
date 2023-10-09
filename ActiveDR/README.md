<p align="center"></p>

ActiveDR + SQL Server Scripts
This folder contains ActiveDR + SQL Server example scripts.
<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

**Files:**
- ActiveDR Failover Test.ps1
- ActiveDR Full Failover.ps1

**Scenario:**
Test failover only in DR.  Do not impact Production

Single test database "CookbookDemo_ADR" on two RDM volumes: a data volume & log volume, on each SQL Server. 

**Prerequisites:**
1. DR Pod needs to be pre-created
2. Databases in DR Pod need to be "initialized" by being presented and attached to the DR SQL Server, then set offline
3. After Step 2 initialization, be sure to retrieve applicable DR disk serial numbers & substitute in code
4. On DR server, SQL Server service off. Service auto-start should be set to Manual as well.

**Usage Notes:**
This script is meant to be run in chunks. Break/exit commands have been added where appropriate. 

This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual organization's 
infrastructure.
<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

We encourage the modification and expansion of these scripts by the community. Although not necessary, please issue a Pull Request (PR) if you wish to request merging your modified code in to this repository.

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

_The contents of the repository are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment. There are no expressed or implied warranties or liability for the use of these example scripts and templates presented by Pure Storage and/or their creators._