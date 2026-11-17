import time
import sys

def main():
    print("Abasthan Background Worker started successfully!")
    sys.stdout.flush()
    
    # 模拟后台持续运行的任务
    counter = 0
    while True:
        counter += 1
        print(f"Worker is running... Loop count: {counter}")
        sys.stdout.flush()
        time.sleep(10)  # 每隔 10 秒输出一次，防止进程退出

if __name__ == "__main__":
    main()
