# Home Network

| Network Name | VLAN        | Domain Name    |
| ------------ | ----------- | -------------- |
| Default      | 1 (untagged |                |
| Lan          | 1           | lan.509ely.com |
| DMZ          | 2           | dmz.509ely.com |
| IOT          | 3           | iot.509ely.com |
| Office       | 4           | wfh.509ely.com |

## Diagram

```txt
Gateway <-> RP --> Tiger (apps.*)
               |_> 10.25.89.20 (lab.*)
```
