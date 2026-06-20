import os
import shutil
import re

def stamp_config_file(path, bootstrap_token, relay_host, api_host, relay_ssh_port, api_port):
    effective_api_host = api_host if api_host else relay_host
    
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        
    content = re.sub(r'RELAY_HOST=.*', f'RELAY_HOST={relay_host}', content)
    content = re.sub(r'RELAY_SSH_PORT=.*', f'RELAY_SSH_PORT={relay_ssh_port}', content)
    content = re.sub(r'ENROLL_API=.*', f'ENROLL_API=http://{effective_api_host}:{api_port}/api/enroll', content)
    content = re.sub(r'BOOTSTRAP_API=.*', f'BOOTSTRAP_API=http://{effective_api_host}:{api_port}/api/bootstrap', content)
    content = re.sub(r'BOOTSTRAP_TOKEN=.*', f'BOOTSTRAP_TOKEN={bootstrap_token}', content)
    content = re.sub(r'ENROLL_CODE=.*', 'ENROLL_CODE=', content)
    content = re.sub(r'ADMIN_PUBLIC_KEY=.*', 'ADMIN_PUBLIC_KEY=', content)
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

def main():
    bootstrap_token = "RLY-TOKEN-2026-AUTOMATION"
    relay_host = "yoong-relay.ddnsgeek.com"
    api_host = "106.13.171.166"
    relay_ssh_port = 22
    api_port = 8787
    
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output_root = os.path.join(project_root, "release", "launcher-kit")
    
    windows_source = os.path.join(project_root, "windows")
    mac_source = os.path.join(project_root, "mac")
    docs_source = os.path.join(project_root, "docs")
    
    if os.path.exists(output_root):
        shutil.rmtree(output_root)
        
    os.makedirs(os.path.join(output_root, "windows"))
    os.makedirs(os.path.join(output_root, "mac"))
    os.makedirs(os.path.join(output_root, "docs"))
    
    def ignore_patterns(path, names):
        return [name for name in names if name == '.DS_Store']
        
    shutil.copytree(windows_source, os.path.join(output_root, "windows"), dirs_exist_ok=True, ignore=ignore_patterns)
    shutil.copytree(mac_source, os.path.join(output_root, "mac"), dirs_exist_ok=True, ignore=ignore_patterns)
    shutil.copytree(docs_source, os.path.join(output_root, "docs"), dirs_exist_ok=True, ignore=ignore_patterns)
    
    stamp_config_file(os.path.join(output_root, "windows", "config.ini"), bootstrap_token, relay_host, api_host, relay_ssh_port, api_port)
    stamp_config_file(os.path.join(output_root, "mac", "config.ini"), bootstrap_token, relay_host, api_host, relay_ssh_port, api_port)
    
    print("Launcher kit prepared at:", output_root)

if __name__ == '__main__':
    main()
