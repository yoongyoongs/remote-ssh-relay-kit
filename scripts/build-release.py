import os
import sys
import shutil
import subprocess

def zip_dir(src_dir, zip_filepath, arcname_func=None):
    """
    压缩目录，保留相对目录结构。
    """
    import zipfile
    if os.path.exists(zip_filepath):
        os.remove(zip_filepath)
        
    with zipfile.ZipFile(zip_filepath, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(src_dir):
            for file in files:
                if file == '.DS_Store':
                    continue
                full_path = os.path.join(root, file)
                if arcname_func:
                    arcname = arcname_func(full_path)
                else:
                    arcname = os.path.relpath(full_path, src_dir)
                zipf.write(full_path, arcname)

def main():
    if len(sys.argv) < 2:
        print("Error: Please specify the version (e.g. v2-29)")
        sys.exit(1)
        
    version = sys.argv[1]
    suffix = f"-{version}" if version else ""
    
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output_root = os.path.join(project_root, "release")
    
    # 1. 运行 prepare-launchers.py 刷新暂存目录
    prepare_script = os.path.join(project_root, "scripts", "prepare-launchers.py")
    print("Running prepare-launchers.py...")
    subprocess.run([sys.executable, prepare_script], check=True)
    
    # 2. 准备打包远端整站代码镜像
    package_dir = os.path.join(output_root, "package")
    if os.path.exists(package_dir):
        # 递归清理旧文件
        for root, dirs, files in os.walk(package_dir, topdown=False):
            for name in files:
                try:
                    os.remove(os.path.join(root, name))
                except Exception:
                    pass
            for name in dirs:
                try:
                    os.rmdir(os.path.join(root, name))
                except Exception:
                    pass
    else:
        os.makedirs(package_dir)
        
    for name in ["server", "windows", "mac", "docs", "scripts", "README.md", "package.json"]:
        src = os.path.join(project_root, name)
        dst = os.path.join(package_dir, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True, ignore=lambda p, names: [n for n in names if n == '.DS_Store'])
        else:
            shutil.copy2(src, dst)
            
    # 3. 压缩整站全套代码 remote-ssh-relay-kit-v2-29.zip
    kit_zip = os.path.join(output_root, f"remote-ssh-relay-kit{suffix}.zip")
    print(f"Creating project kit zip: {kit_zip}...")
    zip_dir(package_dir, kit_zip)
    
    # 4. 如果存在 launcher-kit 暂存目录，打包子端的压缩包
    launcher_kit_path = os.path.join(output_root, "launcher-kit")
    if os.path.exists(launcher_kit_path):
        print(f"Packaging launcher kits with version suffix: {version}")
        
        win_zip = os.path.join(output_root, f"launcher-kit-windows{suffix}.zip")
        mac_zip = os.path.join(output_root, f"launcher-kit-mac{suffix}.zip")
        all_zip = os.path.join(output_root, f"launcher-kit{suffix}.zip")
        
        # 打包 Windows 端 (只包含 windows 子目录下的文件)
        print(f"Creating Windows launcher: {win_zip}...")
        zip_dir(os.path.join(launcher_kit_path, "windows"), win_zip)
        
        # 打包 macOS 端 (只包含 mac 子目录下的文件)
        print(f"Creating macOS launcher: {mac_zip}...")
        zip_dir(os.path.join(launcher_kit_path, "mac"), mac_zip)
        
        # 打包全端通用包 (包含整个 launcher-kit 目录)
        print(f"Creating full launcher: {all_zip}...")
        zip_dir(launcher_kit_path, all_zip)
        
        # 复制一份到根目录作为 windows.zip，兼容旧习惯
        shutil.copy2(win_zip, os.path.join(project_root, "windows.zip"))
        print("Copied Windows launcher to root windows.zip")
        
    print("Release completed successfully!")

if __name__ == '__main__':
    main()
