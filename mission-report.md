# Linux와 OS 미션 — 요구사항 수행 내역서

미션: 컴퓨터가 알아서 자기 상태를 점검하게 만들기  
검토 대상: Ubuntu 실습 환경에서 수집한 condition1~9, when_run, monitor.sh  
증거에 기록된 날짜: 2026-10-04

## 1. 수행 결과와 검토 범위

역할별 계정 및 그룹을 구성하고, 공유·보안 디렉토리에 그룹 권한과 기본 ACL을 적용했다. SSH의 유효 설정은 포트 20022, Root 원격 로그인 차단이며, UFW는 활성화되어 필요한 두 TCP 포트만 인바운드 허용한다. 앱은 agent-admin 일반 계정으로 Boot Sequence 5단계를 통과하고 Agent READY를 출력했다. 앱의 0.0.0.0:15034 LISTEN 상태도 확인했다.

모니터 로그에는 정상 자원 측정과 프로세스 미발견 오류가 모두 시간과 함께 기록되어 있다. 제출한 Bash 소스에는 프로세스·포트 검사, 방화벽 상태 확인, 자원 수집, 임계값 경고, 로그 크기·개수 관리가 구현되어 있다.

## 2. 요구사항별 증거 확인

| 항목 | 확인 내용 | 근거 파일 | 판정 |
|---|---|---|---|
| SSH 포트 변경 | sshd 유효 설정 port 20022, IPv4/IPv6 LISTEN | condition1.txt, when_run.txt | 확인 |
| Root 원격 접속 차단 | sshd 유효 설정 permitrootlogin no | condition1.txt, when_run.txt | 설정 확인 |
| 방화벽 활성화 | Status: active, 기본 incoming deny | condition2.txt, when_run.txt | 확인 |
| 허용 포트 | TCP 20022, 15034만 허용, IPv4/IPv6 적용 | condition2.txt, when_run.txt | 확인 |
| 계정·그룹 | admin/dev/test, common/core 구성과 소속 | condition3.txt | 확인 |
| 디렉토리 권한·ACL | 소유 그룹, rwx 접근권한, default ACL | condition4.txt | 확인 |
| 앱 실행 | agent-admin UID 1000, 5단계 [OK], Agent READY | condition6.txt | 확인 |
| 앱 포트 | 0.0.0.0:15034 LISTEN, agent-app-linux 프로세스 | when_run.txt | 확인 |
| monitor.sh 소유자·그룹 | agent-dev:agent-core | when_run.txt | 확인 |
| 모니터 정상 기록 | PID/CPU/MEM/DISK_USED 형식으로 누적 | condition7~9.txt | 확인 |
| 모니터 실패 기록 | 시각과 [ERROR] 프로세스 미발견 메시지 | condition8~9.txt | 확인 |
| 로그 크기·개수 | 파일당 10 MiB, 현재 파일 포함 최대 10개 구현 | monitor.sh | 구현 확인 |

## 3. 보안 및 네트워크 설정

when_run.txt의 `/usr/sbin/sshd -T` 출력은 다음과 같다.

```text
port 20022
permitrootlogin no
```

`ss -ltnp` 출력에서 sshd가 0.0.0.0:20022 및 [::]:20022를 리슨한다. UFW의 기본 정책은 `deny (incoming), allow (outgoing), deny (routed)`이고, 허용 규칙은 TCP 20022 및 15034의 IPv4/IPv6 항목이다.

SSH 포트 변경은 기본 포트를 대상으로 한 접속 시도를 줄이는 설정이며, Root 원격 로그인 차단은 관리자 권한 계정으로의 직접 원격 접속을 제한한다. 방화벽은 필요한 서비스 포트로 인바운드 접근 범위를 제한한다.

OrbStack 자체 SSH 접근 경로와 Ubuntu OpenSSH 서버는 구분해야 한다. sshd 설정을 실제 접속으로 확인할 때는 Ubuntu OpenSSH의 20022 포트를 사용한다.

## 4. 계정·그룹·디렉토리 권한

| 계정 | UID | 기본 그룹 | 추가 그룹 | 역할 |
|---|---:|---|---|---|
| agent-admin | 1000 | agent-common | agent-core | 앱 실행, 운영, cron 실행 |
| agent-dev | 1001 | agent-common | agent-core | 스크립트 작성, 개발·운영 |
| agent-test | 1002 | agent-common | 없음 | QA·공유 디렉토리 접근 |

agent-common의 GID는 1001, agent-core의 GID는 1002이다. `getent group agent-common`의 마지막 구성원 필드가 비어 있어도 기본 그룹 구성원은 `id` 출력으로 확인할 수 있다. 세 계정 모두 기본 그룹이 agent-common이므로 소속 요구를 충족한다.

| 경로 | 소유자:그룹 | 확인된 모드 | 용도 |
|---|---|---|---|
| /home/agent-admin | agent-admin:agent-common | 750 | common 구성원의 경로 통과 |
| /home/agent-admin/agent-app | agent-admin:agent-common | 755 | 앱 기준 경로 |
| $AGENT_HOME/upload_files | agent-admin:agent-common | 770 + 기본 ACL | common 공유 읽기·쓰기 |
| $AGENT_HOME/api_keys | agent-admin:agent-core | 2770 + 기본 ACL | core만 읽기·쓰기 |
| /var/log/agent-app | root:agent-core | 2770 + 기본 ACL | core만 로그 접근·작성 |
| $AGENT_HOME/bin | agent-admin:agent-core | 750 | core의 목록 조회·실행/통과 |
| $AGENT_HOME/bin/monitor.sh | agent-dev:agent-core | 파일 소유자·그룹 확인 | dev 작성, admin 모니터링 대상 |

세 업무 디렉토리의 ACL 출력에는 `user::rwx`, `group::rwx`, `other::---`와 같은 기본 접근권한뿐 아니라 `default:user::rwx`, `default:group::rwx`, `default:other::---`도 기록되어 있다. 따라서 단순한 ls 출력만이 아니라 기본 ACL 설정까지 증빙된다. 새 파일의 최종 권한에는 생성 시 요청한 모드도 반영되므로 모든 새 파일이 무조건 실행 가능한 것은 아니다.

api_keys와 로그 디렉토리에는 setgid가 적용되어 새 항목의 그룹이 부모 그룹을 상속한다. upload_files에는 setgid가 없지만 현재 세 계정의 기본 그룹이 모두 agent-common이다.

agent-test는 agent-core에 속하지 않아 api_keys와 로그 디렉토리에 접근할 수 없는 권한 구성이다.

## 5. 앱 실행 환경 및 Boot Sequence

| 변수 | 미션 기준값 |
|---|---|
| AGENT_HOME | /home/agent-admin/agent-app |
| AGENT_PORT | 15034 |
| AGENT_UPLOAD_DIR | /home/agent-admin/agent-app/upload_files |
| AGENT_KEY_PATH | /home/agent-admin/agent-app/api_keys/t_secret.key |
| AGENT_LOG_DIR | /var/log/agent-app |

위 표는 미션에서 지정한 실행 환경의 기준값이다. condition6.txt에서 일반 계정 실행, 환경 변수 검사, 키 파일 검사, 포트 가용성, 로그 쓰기 권한의 다섯 단계가 모두 [OK]이고 마지막에 Agent READY가 출력된다. when_run.txt에서는 앱이 0.0.0.0:15034로 리슨한다.

환경 변수는 각 프로세스가 받는 실행 설정이다. 계정의 로그인 시작 위치를 바꾸는 설정은 아니며, 각 계정은 자기 홈에서 시작할 수 있다. cron은 터미널의 export 값을 자동 상속하지 않으므로 스크립트의 기본값 또는 명시적인 환경 설정으로 실행 경로를 고정해야 한다. 제출한 monitor.sh는 AGENT_HOME, 포트, 로그 경로에 기본값을 제공한다.

## 6. 자원 수집 결과와 해석

condition7~9는 동일한 누적 로그를 여러 번 캡처한 자료다. 중복을 제외하면 정상 자원 표본은 3개, 오류 기록은 4개이다.

| 시각 (2026-10-04) | PID | CPU | MEM | 루트 디스크 사용률 |
|---|---|---:|---:|---:|
| 14:03:24 | 4216,4217 | 1.5% | 4.5% | 1% |
| 14:04:02 | 4216,4217 | 5.0% | 5.6% | 1% |
| 14:42:02 | 5515,5516 | 3.9% | 5.1% | 1% |

| 지표 | 평균 | 최소 | 최대 | 경고 조건 |
|---|---:|---:|---:|---|
| CPU | 3.47% | 1.5% | 5.0% | > 20% |
| MEM | 5.07% | 4.5% | 5.6% | > 10% |
| DISK_USED | 1% | 1% | 1% | > 80% |

세 정상 표본에서는 임계값 초과가 없다. 표본 수가 적고 연속 측정 구간도 아니므로 장시간 안정성이나 부하 상황의 성능을 판단하는 근거로 사용하지 않는다. 이 통계는 제출 로그의 요약이며 보너스 report.sh 구현 결과가 아니다.

소스의 CPU는 /proc/stat을 1초 간격으로 읽은 시스템 전체 사용률이며 idle과 iowait는 비사용 구간으로 계산한다. MEM은 `(MemTotal - MemAvailable) / MemTotal`, DISK_USED는 `df -P /`의 사용률이다. PID는 점검 대상 앱이고 자원 수치는 해당 앱만의 점유율이 아니라 시스템 지표다.

14:40:43, 14:41:01, 14:43:02, 14:44:01에는 agent-admin 소유의 대상 프로세스를 찾지 못한 오류가 기록된다. 14:42:02의 정상 기록은 해당 점검 시점에 프로세스·포트 검사를 통과하고 자원 수집까지 완료했음을 나타낸다. 이 자료만으로 이후 프로세스 미발견의 원인을 특정할 수는 없다.

## 7. monitor.sh 구현 및 검증

첨부 소스는 원본 monitor(2).sh의 내용을 수정하지 않고 monitor.sh라는 제출 파일명으로 보존했다. 변수 선언 → 함수 정의 → 검사·수집·기록 흐름 → 최종 출력 순서로 구성되어 있다.

1. agent-admin 소유의 agent-app-linux-x86 프로세스를 검색하고 상태를 확인한다. 미발견 또는 중지·좀비·종료 상태에서는 오류를 기록하고 exit 1로 종료한다. D 상태는 경고한다.
2. TCP 15034의 LISTEN 상태를 검사한다. 실패하면 오류를 기록하고 exit 1로 종료한다. 포트 검사는 리슨 여부를 확인하며 소유 프로세스와의 동일성까지 검사하지는 않는다.
3. `sudo -n /usr/sbin/ufw status`로 상태를 확인한다. 비활성 또는 조회 실패는 [WARNING]으로 처리하고 계속 진행한다. 일반 계정 실행에는 해당 명령에 한정된 NOPASSWD sudo 설정이 필요하다.
4. CPU·메모리·루트 디스크 사용률을 수집하고 지정 임계값을 초과할 때 경고한다.
5. 성공 시 지정 자원 포맷, 실패 시 시각과 [ERROR] 메시지를 같은 monitor.log에 기록한다. 실패 시 수집하지 못한 자원 값을 정상 수치로 꾸며 기록하지 않는다.
6. flock으로 기록·회전을 직렬화하고, 파일 크기는 10 × 1024 × 1024바이트, 파일 수는 monitor.log 및 .1~.9의 총 10개로 관리한다. 엄밀한 크기 단위는 10 MiB이다.

성공 포맷은 다음과 같다.

```text
[2026-10-04 14:42:02] PID:5515,5516 CPU:3.9% MEM:5.1% DISK_USED:1%
```

실패 포맷은 다음과 같다.

```text
[2026-10-04 14:44:01] [ERROR] Process 'agent-app-linux-x86' not found for user 'agent-admin'.
```

제출 소스에 대한 `bash -n` 문법 검사는 통과했다. 실제 정상/실패 로그는 첨부 실행 기록으로 확인했다. 로그 저장에 실패하는 경우에는 stderr로 오류를 출력하도록 구현되어 있다.

## 8. 자동 실행 구성

monitor.sh는 cron에서 일반 계정으로 실행할 수 있도록 PATH와 실행 환경 기본값을 소스에 정의했다. 미션의 실행 주기는 매분이며 실행 계정은 agent-admin이다. 이에 대응하는 cron 실행식은 다음과 같다.

```cron
* * * * * /bin/bash /home/agent-admin/agent-app/bin/monitor.sh
```

누적 로그에는 14:41:01, 14:42:02, 14:43:02, 14:44:01의 기록이 있으며, 각 실행 시점의 정상 자원 값 또는 프로세스 점검 오류를 시간과 함께 보존한다. 위 실행식은 매분 실행 구성식이며, 첨부 로그는 관측된 실행 기록이다.

## 9. 제출 파일 구성 및 원본 보존

| 묶음 내 파일 | 원본/역할 |
|---|---|
| mission-report.md | 수행 결과, 증거 대응, 자원 요약을 정리한 문서 1개 |
| monitor.sh | monitor(2).sh 원본 코드, 바이트 그대로 보존 |
| evidence/condition1.txt~condition9.txt | condition1(1)~condition9(1), 내용 그대로 보존 |
| evidence/when_run.txt | 추가 SSH·UFW·소켓·경로 권한 증거, 내용 그대로 보존 |

condition7 원문에 있는 리다이렉션 대상 condition6 표기는 원본 그대로 보존했다. 파일명과 파일 내용의 역할은 위 대응표를 기준으로 해석한다. 첨부 증거와 스크립트 내용은 원본 그대로 보존했다.
