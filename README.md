# Unikraft Cloud Script

This script deploys unikraft generated KVM target unikernels on **Digitalocean Cloud Platform**

## Installation

Copy the script to `/usr/local/bin` 

```
sudo cp deploy-unikraft-do.sh /usr/local/bin/
```
Please make sure that `/usr/local/bin` is in your `PATH`

**OR**

You can directly run the script like - 

```bash
./<path/of/deploy-unikraft-do.sh>
Eg, ./deploy-unikraft-do.sh (If the script is in current dir)
```


## Usage
Please make sure that you have a working digitalocean account.  
If not, please create one (click [here](https://www.digitalocean.com/)).
 

```
usage: ./deploy-unikraft-do.sh [-h] [-v] -k <unikernel> -b <bucket> -p <config-path> [-n <name>]
       [-r <region>] [-i <instance-type>] [-t <tag>] [-s]

Mandatory Args:
<unikernel>: 	  Name/Path of the unikernel (Please use "KVM" target images) 
<bucket>: 	  Digitalocean bucket name

Optional Args:
<name>: 	  Image name to use on the cloud (default: unikraft)
<region>: 	  Digitalocean region (default: fra1)
<instance-type>:  Specify the type of the machine on which you wish to deploy the unikernel (default: s-1vcpu-1gb) 
<-v>: 		  Turns on verbose mode
<-s>: 		  Automatically starts an instance on the cloud



```

## Bug Report
For major changes, please open an issue first to discuss what you would like to change.
