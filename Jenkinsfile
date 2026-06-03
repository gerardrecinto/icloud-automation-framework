// iCloud automation framework CI pipeline.
// Stages: lint -> swift build -> xctest -> triage -> publish
// Runs on macOS agents with Xcode 15+.

pipeline {
    agent {
        label 'macos-xcode15'
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timestamps()
        ansiColor('xterm')
    }

    environment {
        SCHEME         = "ICloudTestFramework"
        XCRESULT_PATH  = "build/TestResults.xcresult"
        TRIAGE_REPORT  = "build/triage-report.json"
    }

    stages {
        stage('Setup') {
            steps {
                sh '''
                    swift --version
                    xcodebuild -version
                    python3 --version
                    pip3 install --quiet --upgrade pip
                '''
            }
        }

        stage('Swift Build') {
            steps {
                sh 'swift build -c release 2>&1 | tee build/swift-build.log'
            }
            post {
                failure {
                    sh 'python3 scripts/triage.py log build/swift-build.log || true'
                }
            }
        }

        stage('Lint') {
            steps {
                sh '''
                    if command -v swiftlint &>/dev/null; then
                        swiftlint --strict --reporter github-actions-logging
                    else
                        echo "swiftlint not installed — skipping"
                    fi
                '''
            }
        }

        stage('XCTest') {
            steps {
                sh '''
                    mkdir -p build
                    set -o pipefail
                    xcodebuild test \
                        -scheme "${SCHEME}" \
                        -destination "platform=macOS" \
                        -resultBundlePath "${XCRESULT_PATH}" \
                        CODE_SIGN_IDENTITY="" \
                        CODE_SIGNING_REQUIRED=NO \
                        2>&1 | xcpretty --report junit --output build/test-results.xml || true
                '''
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'build/test-results.xml'
                }
            }
        }

        stage('Triage Failures') {
            steps {
                sh '''
                    if [ -d "${XCRESULT_PATH}" ]; then
                        python3 scripts/triage.py xcresult "${XCRESULT_PATH}" \
                            --json > "${TRIAGE_REPORT}" || true
                        python3 scripts/triage.py xcresult "${XCRESULT_PATH}" -v
                    elif [ -f build/test-results.xml ]; then
                        echo "xcresult not found — falling back to log triage"
                    fi
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'build/triage-report.json',
                                     allowEmptyArchive: true
                }
            }
        }

        stage('Coverage Check') {
            steps {
                sh '''
                    python3 scripts/coverage_gap.py \
                        --source Sources/ \
                        --tests Tests/ \
                        --min-coverage 80 || true
                '''
            }
        }

        stage('Publish Artifacts') {
            when {
                branch 'main'
            }
            steps {
                archiveArtifacts artifacts: 'build/**/*.xcresult, build/triage-report.json',
                                 allowEmptyArchive: true
            }
        }
    }

    post {
        failure {
            script {
                def triageExists = fileExists(env.TRIAGE_REPORT)
                if (triageExists) {
                    def report = readJSON file: env.TRIAGE_REPORT
                    def actionable = report.get('actionable', []).size()
                    def infra = (report.get('by_category') ?: [:]).get('infrastructure', 0)
                    echo "Triage: ${actionable} actionable failures, ${infra} infrastructure failures"
                }
            }
        }
        cleanup {
            sh 'swift package clean || true'
        }
    }
}
