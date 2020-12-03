## Docker

Recommend: Ubuntu 18.0.4 

**2 Minutes** to both install Docker, and create an account!

Once docker boots, visit http://localhost, Sign up with any login you like.

![docker install](docker-install.gif)  

!!! warning "Linux only: Change port 22 for CDR SFTP"
    Since we run our own SFTP server, so we need to change Linux's SSH port from 22 to 2222 (or any other port than 22). 
    ```
    echo "Port 2222" >> /etc/ssh/sshd_config
    systemctl restart sshd.service
    ```

    You will have to SSH to Linux on 2222 now, instead of 22.


#### Grab the Docker Compose file and Launch the containers!
``` bash
sudo snap install docker
sudo apt-get install docker-compose
mkdir calltelemetry
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/docker-compose.yml
cd calltelemetry
sudo docker-compose up
```