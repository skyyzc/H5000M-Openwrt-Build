#!/usr/bin/env bash
#
# check-workflow-contracts.sh — 校验复用工作流的调用契约。
#
# 为什么需要这个脚本：有一种 CI 故障是**完全静默**的。当 build.yml 以
# `uses: ./.github/workflows/x.yml` 调用另一个工作流时，若被调用方声明的
# 权限**超出**调用方已授予的权限，GitHub 会在**启动期**直接拒绝整个工作流：
#
#     构建 H5000M 主线 OpenWrt 固件   completed/startup_failure
#
# 没有 job、没有步骤、没有错误文本，Actions 页面只有一句结论。这个仓库因此
# 在 PR #1 之后的一段时间里**固件构建完全无法启动**，而 build.yml 只在
# schedule / tag / dispatch 时运行，所以任何 PR 门禁都不会暴露它——是靠人工
# 逐个二分才定位到的。
#
# 同类问题还有：调用方 `with:` 传了被调用方未声明的输入；被调用方文件不存在；
# 表达式里对含连字符的标识符用点号访问（`inputs.artifact-name` 会被解析成
# `inputs.artifact - name`，同样是启动期失败）。
#
# 这个脚本把上述契约变成可自动检查的断言，本地与 CI 都能跑。
#
# Usage: scripts/check-workflow-contracts.sh [仓库根目录]
#
set -Eeuo pipefail

ROOT_DIR="$(cd "${1:-"$(dirname "${BASH_SOURCE[0]}")/.."}" && pwd)"
cd "$ROOT_DIR"

command -v python3 >/dev/null 2>&1 || {
	echo "需要 python3" >&2
	exit 2
}
python3 - "$ROOT_DIR" <<'PY'
import pathlib
import re
import sys

import yaml

root = pathlib.Path(sys.argv[1])
wf_dir = root / ".github" / "workflows"
act_dir = root / ".github" / "actions"

problems: list[str] = []
checked_calls = 0


def load(path: pathlib.Path):
    """YAML 1.1 会把裸 `on:` 解析成布尔 True，因此要转回字符串键。"""
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        return {}
    if True in data and "on" not in data:
        data["on"] = data.pop(True)
    return data


def as_set(mapping) -> set:
    return set((mapping or {}).keys())


# ---------------------------------------------------------------------------
# 1) 表达式里对含连字符的标识符用点号访问
# ---------------------------------------------------------------------------
# `${{ inputs.artifact-name }}` 被解析为减法，表达式编译失败。被复用工作流
# 引用时，故障上抛为调用方的 startup_failure。
DOTTED_HYPHEN = re.compile(
    r"\$\{\{[^}]*\b(inputs|steps|needs|jobs|secrets|matrix|env)"
    r"\.[A-Za-z0-9_]+-[A-Za-z0-9_]"
)

for path in sorted(list(wf_dir.glob("*.yml")) + list(act_dir.rglob("action.yml"))):
    text = path.read_text()
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if DOTTED_HYPHEN.search(line):
            problems.append(
                f"{path.relative_to(root)}:{i}: 表达式里对含连字符的标识符用了点号访问；"
                f"`-` 会被当作减法，导致启动期失败。请改用 snake_case 标识符或方括号写法。"
            )

# ---------------------------------------------------------------------------
# 2) 复用工作流调用契约
# ---------------------------------------------------------------------------
for path in sorted(wf_dir.glob("*.yml")):
    data = load(path)
    jobs = data.get("jobs") or {}
    caller_top = as_set(data.get("permissions"))

    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        uses = job.get("uses")
        if not isinstance(uses, str) or not uses.startswith("./"):
            continue
        checked_calls += 1

        target = (root / uses).resolve()  # 相对仓库根；直接 join，lstrip("./") 会吃掉 .github 的点
        if not target.exists():
            problems.append(
                f"{path.relative_to(root)}: job {job_id} 引用了不存在的 {uses}"
            )
            continue

        callee = load(target)
        # `workflow_call:` with nothing underneath is a legal declaration - the
        # callee simply takes no inputs - and PyYAML collapses it to None.  So
        # `is None` cannot tell "declared, no inputs" from "not declared", and
        # it reported the former as a missing contract.  That went unnoticed
        # because the only other callee here, reusable-script-test.yml, happens
        # to declare inputs and so never took the empty branch; the first
        # no-input callee (attest.yml) hit it immediately.  Membership in the
        # `on` mapping answers the question that was actually being asked.
        on_block = callee.get("on") or {}
        if "workflow_call" not in on_block:
            problems.append(
                f"{path.relative_to(root)}: job {job_id} 调用了 {uses}，"
                f"但它没有声明 on.workflow_call"
            )
            continue
        wc = on_block.get("workflow_call") or {}

        # 2a) with: 的键必须是被调用方声明的输入
        declared = as_set(wc.get("inputs"))
        for key in as_set(job.get("with")):
            if key not in declared:
                problems.append(
                    f"{path.relative_to(root)}: job {job_id} 传给 {uses} 的输入 "
                    f"`{key}` 未在被调用方声明（已声明：{sorted(declared)}）"
                )
        # 必填输入必须传
        for key, spec in (wc.get("inputs") or {}).items():
            if isinstance(spec, dict) and spec.get("required") and key not in as_set(job.get("with")):
                problems.append(
                    f"{path.relative_to(root)}: job {job_id} 未传必填输入 `{key}` 给 {uses}"
                )

        # 2b) 权限子集：被调用方 job 请求的权限必须是调用方已授予的子集。
        #     这就是让 build.yml 完全无法启动的那条规则。
        caller_granted = as_set(job.get("permissions")) or caller_top
        for cj_id, cj in (callee.get("jobs") or {}).items():
            if not isinstance(cj, dict):
                continue
            callee_wants = as_set(cj.get("permissions")) or as_set(callee.get("permissions"))
            missing = callee_wants - caller_granted
            if missing:
                problems.append(
                    f"{path.relative_to(root)}: job {job_id} 调用 {uses}，"
                    f"而被调用方 job {cj_id} 申请了调用方未授予的权限 "
                    f"{sorted(missing)}（调用方授予 {sorted(caller_granted)}）——"
                    f"GitHub 会在启动期拒绝整个工作流（startup_failure）"
                )

# ---------------------------------------------------------------------------
# 3) `gh` 调用必须能在没有 checkout 的 job 里定位仓库
# ---------------------------------------------------------------------------
# `gh` 从**当前目录的 git remote** 推断仓库。一个没有 `actions/checkout` 的
# job（典型：release-please 这种纯 API 的容器 action）里，工作区之上根本不存在
# `.git`，于是每个 `gh` 调用都死于：
#
#     failed to run git: fatal: not a git repository ...
#
# 这个故障在 v1.1.3 上真实发生：`gh workflow run` 已经派发成功（派发不需要本地
# 仓库），紧接着用于**确认**派发的 `gh run list` 挂掉，整个 job 失败，tag 因此
# 一个固件产物都没有。派发成功 + 校验崩溃 = 最坏的组合，因为它看起来像失败，
# 而队列里其实躺着一个没人确认的构建。
#
# 检查规则：任何执行 `gh <子命令>` 的步骤，若同一 job 中此前没有 checkout，
# 就必须通过 `GH_REPO` 显式给出仓库（步骤 / job / 工作流级 env 均可）。
GH_SUBCMD = re.compile(
    r"(?:^|[^\w-])gh\s+(?:api|run|release|workflow|pr|repo|auth|issue|label|"
    r"secret|variable|cache|gist|attestation|ruleset|search|status)\b"
)


def gh_invocations(run: str):
    """返回真正**执行** gh 的行。

    纯文本匹配会把诊断用的人话也算进来：diagnose action 里对用户打印的
    ``echo "复现：\\`gh run view ...\\`"`` 并不执行 gh。因此对 echo/printf/cat
    这类纯打印语句，只有在 gh 位于**命令替换**（未转义的 ``$(`` 或反引号）之后时
    才算调用——这样 `echo "$(gh run list)"` 仍会被抓到，而转义反引号里的示例文本
    不会。`gh` 出现在 `if gh ...`、`files=$(gh ...)` 等真实命令位置时照常匹配。
    """
    out = []
    for raw in run.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        candidate = line
        if line.split(None, 1)[0] in ("echo", "printf", "cat"):
            m = re.search(r"\$\(|(?<!\\)`", line)
            if m is None:
                continue
            candidate = line[m.start():]
        if GH_SUBCMD.search(candidate):
            out.append(line)
    return out


for path in sorted(list(wf_dir.glob("*.yml")) + list(act_dir.rglob("action.yml"))):
    data = load(path)
    wf_env = as_set(data.get("env"))
    # 复合 action 没有 job 概念，视为单个 job
    if "runs" in data:
        jobs_iter = [(None, data.get("runs") or {})]
    else:
        jobs_iter = [
            (jid, j) for jid, j in (data.get("jobs") or {}).items() if isinstance(j, dict)
        ]

    for job_id, job in jobs_iter:
        job_env = as_set(job.get("env"))
        has_checkout = False
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            # checkout（含本地 path 形式）会让 `.git` 出现在工作区
            uses = step.get("uses")
            if isinstance(uses, str) and uses.startswith("actions/checkout@"):
                has_checkout = True
                continue

            run = step.get("run")
            if not isinstance(run, str):
                continue
            hits = gh_invocations(run)
            if not hits:
                continue
            if has_checkout:
                continue
            step_env = as_set(step.get("env"))
            if "GH_REPO" in (step_env | job_env | wf_env):
                continue
            where = f"job {job_id} " if job_id else ""
            problems.append(
                f"{path.relative_to(root)}: {where}步骤 `{step.get('name', '<未命名>')}` "
                f"调用了 gh（{hits[0].strip()[:60]}…），但该 job 中没有 actions/checkout，"
                f"也未设置 GH_REPO。gh 依赖当前目录的 git remote 推断仓库，"
                f"会直接失败（v1.1.3 因此没有产出固件）。"
                f"请加 `GH_REPO: ${{{{ github.repository }}}}`。"
            )


# ---------------------------------------------------------------------------
# 4) `runs-on` 不得使用浮动的 `*-latest` 标签
# ---------------------------------------------------------------------------
# `ubuntu-latest` 不是版本，而是一个**会移动**的指针：GitHub 用它来回切换
# 默认镜像。于是同一个 commit 在不同日子会跑在不同的发行版上——对一个发布
# 固件 / 写 apk 仓库的 job 来说，这是没有 commit 可审的运行环境变更。
#
# 这个仓库因此真实吃到过告警：`publish-apk-repo` 是全仓唯一用 `ubuntu-latest`
# 的 job，run 36282274537 上 GitHub 给它挂了一条注释
#
#     The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19,
#     2026.
#
# 其余 9 个 job 早已钉住 `ubuntu-24.04`，只有这一个漏了。检查规则：`runs-on`
# 里的每个标签都不得以 `-latest` 结尾。矩阵 / 表达式的值不在此处判断（它们
# 由输入决定），只查字面量与列表字面量。
def runner_labels(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            if isinstance(v, str):
                yield v


for path in sorted(wf_dir.glob("*.yml")):
    data = load(path)
    for job_id, job in (data.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for label in runner_labels(job.get("runs-on")):
            if label.endswith("-latest"):
                problems.append(
                    f"{path.relative_to(root)}: job {job_id} 的 runs-on 用了浮动标签 "
                    f"`{label}`。它指向的镜像会随时移动，同一个 commit 会在不同日子"
                    f"跑在不同发行版上（run 36282274537 实测：GitHub 对 "
                    f"ubuntu-latest 挂了 Ubuntu 26 迁移告警）。请钉住具体版本，"
                    f"例如 `ubuntu-24.04`。"
                )


# ---------------------------------------------------------------------------
if problems:
    print(f"\033[31m✗ 发现 {len(problems)} 处复用工作流契约问题：\033[0m\n")
    for p in problems:
        print(f"  - {p}")
    print()
    sys.exit(1)

print(
    f"\033[32m✓ 复用工作流契约正常\033[0m"
    f"（检查了 {checked_calls} 处 uses: ./ 调用、表达式中的连字符点号访问，"
    f"以及 runs-on 的浮动标签）"
)
PY
