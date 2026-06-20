import sys

def add_bom(path):
    # 使用 utf-8-sig 读取，它会自动剥离已有的 BOM，防止重复添加
    with open(path, 'r', encoding='utf-8-sig') as f:
        content = f.read()
    # 使用 utf-8-sig 写入，它会自动在文件头部添加 BOM 字节 (0xEF, 0xBB, 0xBF)
    with open(path, 'w', encoding='utf-8-sig') as f:
        f.write(content)

if __name__ == '__main__':
    for path in sys.argv[1:]:
        add_bom(path)
        print(f"Added BOM to: {path}")
