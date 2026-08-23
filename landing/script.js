/* ==========================================================================
   XDM — Extreme Download Manager
   Landing Page Interactive JavaScript Engine
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
    'use strict';

    // 1. --- OS DETECTION & DYNAMIC HERO CTA ---
    const detectUserOS = () => {
        const ua = navigator.userAgent;
        let isAndroid = /Android/i.test(ua);
        
        const detectorEl = document.getElementById('osDetectorLabel');
        const heroBtnText = document.getElementById('heroDetectedText');
        const heroAutoDownloadBtn = document.getElementById('heroAutoDownloadBtn');

        if (isAndroid) {
            if (detectorEl) detectorEl.textContent = '✓ Android Device Detected • Direct APK Download • 100% Ad-Free';
            if (heroBtnText) heroBtnText.textContent = 'Download Android APK (Direct)';
        } else {
            if (detectorEl) detectorEl.textContent = '✓ Live Build: Android (8.0+) • Desktop & iOS in Roadmap';
            if (heroBtnText) heroBtnText.textContent = 'Download Android APK (v3.0)';
        }

        if (heroAutoDownloadBtn) {
            heroAutoDownloadBtn.href = 'https://github.com/DevEslam1/XDM/releases/latest';
            heroAutoDownloadBtn.setAttribute('target', '_blank');
            heroAutoDownloadBtn.setAttribute('rel', 'noopener');
        }

        // Default to Android active tab
        switchPlatformTab('android');
    };

    // 2. --- THEME SWITCHER ---
    const htmlEl = document.documentElement;
    const themeToggle = document.getElementById('themeToggle');
    const themeDropdown = document.getElementById('themeDropdown');
    const themeOptions = document.querySelectorAll('.theme-opt');

    const savedTheme = localStorage.getItem('xdm-landing-theme') || 'cyber';
    htmlEl.setAttribute('data-theme', savedTheme);
    updateActiveThemeOption(savedTheme);

    if (themeToggle && themeDropdown) {
        themeToggle.addEventListener('click', (e) => {
            e.stopPropagation();
            themeDropdown.classList.toggle('show');
        });

        document.addEventListener('click', () => {
            themeDropdown.classList.remove('show');
        });

        themeOptions.forEach(opt => {
            opt.addEventListener('click', () => {
                const themeVal = opt.dataset.themeVal;
                htmlEl.setAttribute('data-theme', themeVal);
                localStorage.setItem('xdm-landing-theme', themeVal);
                updateActiveThemeOption(themeVal);
                themeDropdown.classList.remove('show');
                showToast(`Switched to ${opt.textContent.trim()} theme`);
            });
        });
    }

    function updateActiveThemeOption(theme) {
        themeOptions.forEach(opt => {
            opt.classList.toggle('active', opt.dataset.themeVal === theme);
        });
    }

    // 3. --- PLATFORM DOWNLOAD TABS ---
    const platTabs = document.querySelectorAll('.plat-tab');
    const platPanels = document.querySelectorAll('.plat-panel');

    function switchPlatformTab(platform) {
        platTabs.forEach(tab => {
            tab.classList.toggle('active', tab.dataset.platform === platform);
        });
        platPanels.forEach(panel => {
            panel.classList.toggle('active', panel.id === `panel-${platform}`);
        });
    }

    platTabs.forEach(tab => {
        tab.addEventListener('click', () => {
            switchPlatformTab(tab.dataset.platform);
        });
    });

    // 4. --- GITHUB API (STARS & VERSION) ---
    const fetchGitHubStats = async () => {
        try {
            const res = await fetch('https://api.github.com/repos/DevEslam1/XDM');
            if (res.ok) {
                const data = await res.json();
                const starEl = document.getElementById('githubStars');
                if (starEl && data.stargazers_count) {
                    starEl.textContent = `★ ${(data.stargazers_count / 1000).toFixed(1)}k`;
                }
            }
        } catch (err) {
            console.warn('GitHub stats fallback active');
        }
    };
    fetchGitHubStats();

    // 5. --- INTERACTIVE VELOCITY SIMULATOR ---
    const simStartBtn = document.getElementById('simStartBtn');
    const simBtnText = document.getElementById('simBtnText');
    const simThreadSelect = document.getElementById('simThreadSelect');
    const simSegmentsGrid = document.getElementById('simSegmentsGrid');
    const simSpeedVal = document.getElementById('simSpeedVal');
    const simEtaVal = document.getElementById('simEtaVal');
    const simTotalPercent = document.getElementById('simTotalPercent');
    const simBytesTransferred = document.getElementById('simBytesTransferred');
    const simWorkerCount = document.getElementById('simWorkerCount');
    const simTerminalLog = document.getElementById('simTerminalLog');

    let simRunning = false;
    let simInterval = null;

    function renderSimulatorSegments(count) {
        if (!simSegmentsGrid) return;
        simSegmentsGrid.innerHTML = '';
        for (let i = 1; i <= count; i++) {
            const seg = document.createElement('div');
            seg.className = 'seg-box';
            seg.id = `seg-${i}`;
            seg.innerHTML = `
                <div class="seg-top">
                    <span>Segment #${i < 10 ? '0' + i : i}</span>
                    <span class="seg-pct">0%</span>
                </div>
                <div class="seg-bar-bg">
                    <div class="seg-bar-fill"></div>
                </div>
            `;
            simSegmentsGrid.appendChild(seg);
        }
    }

    renderSimulatorSegments(16);

    if (simThreadSelect) {
        simThreadSelect.addEventListener('change', (e) => {
            const count = parseInt(e.target.value, 10);
            renderSimulatorSegments(count);
            if (simWorkerCount) simWorkerCount.textContent = `${count} Isolates`;
            logTerminal(`[Config] Reallocated isolate thread pool to ${count} parallel workers.`);
        });
    }

    function logTerminal(msg) {
        if (!simTerminalLog) return;
        const line = document.createElement('div');
        line.className = 'log-line';
        line.textContent = msg;
        simTerminalLog.appendChild(line);
        simTerminalLog.scrollTop = simTerminalLog.scrollHeight;
    }

    if (simStartBtn) {
        simStartBtn.addEventListener('click', () => {
            if (simRunning) {
                stopSimulator();
                return;
            }
            startSimulator();
        });
    }

    function startSimulator() {
        simRunning = true;
        if (simBtnText) simBtnText.textContent = 'Pause Benchmark';
        const threads = parseInt(simThreadSelect ? simThreadSelect.value : '16', 10);
        renderSimulatorSegments(threads);
        logTerminal(`[Engine] Initializing HTTP/3 range stream across ${threads} isolates...`);
        logTerminal(`[CRC32] Append-only journal initialized.`);

        let progress = Array(threads).fill(0);
        let totalDownloaded = 0;
        const targetSizeMB = 4200; // 4.2 GB

        simInterval = setInterval(() => {
            let allDone = true;
            let sumPercent = 0;

            for (let i = 0; i < threads; i++) {
                if (progress[i] < 100) {
                    allDone = false;
                    const delta = 1.5 + Math.random() * 3.8;
                    progress[i] = Math.min(100, progress[i] + delta);
                }
                sumPercent += progress[i];

                const segEl = document.getElementById(`seg-${i + 1}`);
                if (segEl) {
                    const fill = segEl.querySelector('.seg-bar-fill');
                    const pct = segEl.querySelector('.seg-pct');
                    if (fill) fill.style.width = `${progress[i]}%`;
                    if (pct) pct.textContent = `${Math.floor(progress[i])}%`;
                }
            }

            const overallPct = Math.floor(sumPercent / threads);
            const currentSpeed = (95 + Math.random() * 55).toFixed(1);
            totalDownloaded = ((overallPct / 100) * targetSizeMB).toFixed(0);

            if (simSpeedVal) simSpeedVal.textContent = currentSpeed;
            if (simTotalPercent) simTotalPercent.textContent = `${overallPct}%`;
            if (simBytesTransferred) simBytesTransferred.textContent = `${totalDownloaded} MB / 4.2 GB`;

            const remSeconds = Math.max(1, Math.round(((100 - overallPct) / 100) * 12));
            if (simEtaVal) simEtaVal.textContent = `Streaming • ETA: ${remSeconds}s`;

            if (overallPct === 50) {
                logTerminal(`[Integrity] Spot-checking 64KB chunk boundaries: PASSED`);
            }

            if (allDone) {
                clearInterval(simInterval);
                simRunning = false;
                if (simBtnText) simBtnText.textContent = 'Restart Benchmark';
                if (simSpeedVal) simSpeedVal.textContent = '0.0';
                if (simEtaVal) simEtaVal.textContent = '✓ Download & CRC32 Verification Complete!';
                logTerminal(`[Success] 4.2 GB file downloaded in 9.4s at peak 148 MB/s!`);
                showToast('Velocity test completed with 100% data integrity!');
            }
        }, 180);
    }

    function stopSimulator() {
        simRunning = false;
        clearInterval(simInterval);
        if (simBtnText) simBtnText.textContent = 'Resume Velocity Test';
        if (simSpeedVal) simSpeedVal.textContent = '0.0';
        if (simEtaVal) simEtaVal.textContent = 'Paused by User';
        logTerminal(`[Engine] All worker isolates suspended.`);
    }

    // 6. --- COPY TO CLIPBOARD HANDLERS ---
    const toastBubble = document.getElementById('toastBubble');
    const toastMessage = document.getElementById('toastMessage');
    let toastTimeout = null;

    function showToast(msg) {
        if (!toastBubble || !toastMessage) return;
        toastMessage.textContent = msg;
        toastBubble.classList.add('show');
        clearTimeout(toastTimeout);
        toastTimeout = setTimeout(() => {
            toastBubble.classList.remove('show');
        }, 2800);
    }

    // CLI Copy buttons
    document.querySelectorAll('.cli-copy-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const cmd = btn.dataset.cli;
            if (cmd) {
                navigator.clipboard.writeText(cmd).then(() => {
                    const originalText = btn.textContent;
                    btn.textContent = 'Copied!';
                    showToast(`Copied command: ${cmd}`);
                    setTimeout(() => { btn.textContent = originalText; }, 2000);
                });
            }
        });
    });

    // Checksum copy
    document.querySelectorAll('.copy-checksum-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const hash = btn.dataset.copy;
            if (hash) {
                navigator.clipboard.writeText(hash).then(() => {
                    showToast('SHA-256 Checksum copied!');
                });
            }
        });
    });

    // 7. --- SHARE MODAL & VIRAL SHARING ---
    const shareModalBackdrop = document.getElementById('shareModalBackdrop');
    const openShareModal = document.getElementById('openShareModal');
    const mobileShareBtn = document.getElementById('mobileShareBtn');
    const ctaShareBtn = document.getElementById('ctaShareBtn');
    const closeShareModal = document.getElementById('closeShareModal');
    const copyShareUrlBtn = document.getElementById('copyShareUrlBtn');
    const shareUrlInput = document.getElementById('shareUrlInput');

    const handleShareAction = () => {
        if (navigator.share) {
            navigator.share({
                title: 'XDM — Extreme Download Manager',
                text: 'Check out XDM — a multi-threaded, 16-segment download manager & BitTorrent client for desktop and mobile!',
                url: window.location.href
            }).catch(() => {
                showShareModal();
            });
        } else {
            showShareModal();
        }
    };

    function showShareModal() {
        if (shareModalBackdrop) {
            shareModalBackdrop.classList.add('open');
            shareModalBackdrop.setAttribute('aria-hidden', 'false');
        }
    }

    function hideShareModal() {
        if (shareModalBackdrop) {
            shareModalBackdrop.classList.remove('open');
            shareModalBackdrop.setAttribute('aria-hidden', 'true');
        }
    }

    if (openShareModal) openShareModal.addEventListener('click', handleShareAction);
    if (mobileShareBtn) mobileShareBtn.addEventListener('click', handleShareAction);
    if (ctaShareBtn) ctaShareBtn.addEventListener('click', handleShareAction);
    if (closeShareModal) closeShareModal.addEventListener('click', hideShareModal);

    if (shareModalBackdrop) {
        shareModalBackdrop.addEventListener('click', (e) => {
            if (e.target === shareModalBackdrop) hideShareModal();
        });
    }

    if (copyShareUrlBtn && shareUrlInput) {
        copyShareUrlBtn.addEventListener('click', () => {
            navigator.clipboard.writeText(shareUrlInput.value).then(() => {
                showToast('Share link copied to clipboard!');
                copyShareUrlBtn.textContent = 'Copied!';
                setTimeout(() => { copyShareUrlBtn.textContent = 'Copy Link'; }, 2000);
            });
        });
    }

    // 8. --- FAQ ACCORDION ---
    document.querySelectorAll('.faq-item').forEach(item => {
        const questionBtn = item.querySelector('.faq-question');
        if (questionBtn) {
            questionBtn.addEventListener('click', () => {
                const isOpen = item.classList.contains('open');
                document.querySelectorAll('.faq-item').forEach(other => other.classList.remove('open'));
                if (!isOpen) item.classList.add('open');
            });
        }
    });

    // 9. --- MOBILE MENU TOGGLE ---
    const mobileToggle = document.getElementById('mobileToggle');
    const mobileMenu = document.getElementById('mobileMenu');
    if (mobileToggle && mobileMenu) {
        mobileToggle.addEventListener('click', (e) => {
            e.stopPropagation();
            const isOpen = mobileMenu.classList.toggle('open');
            mobileToggle.classList.toggle('open', isOpen);
            mobileToggle.setAttribute('aria-expanded', String(isOpen));
        });

        document.querySelectorAll('.mobile-link, .mobile-actions a, .mobile-actions button').forEach(link => {
            link.addEventListener('click', () => {
                mobileMenu.classList.remove('open');
                mobileToggle.classList.remove('open');
                mobileToggle.setAttribute('aria-expanded', 'false');
            });
        });

        document.addEventListener('click', (e) => {
            if (!mobileMenu.contains(e.target) && !mobileToggle.contains(e.target)) {
                mobileMenu.classList.remove('open');
                mobileToggle.classList.remove('open');
                mobileToggle.setAttribute('aria-expanded', 'false');
            }
        });
    }

    // 10. --- HERO LIVE SPARKLINE GRAPH ---
    const heroSparkLine = document.getElementById('heroSparkLine');
    const heroSparkArea = document.getElementById('heroSparkArea');
    const heroLiveSpeed = document.getElementById('heroLiveSpeed');
    const task1Speed = document.getElementById('task1Speed');

    if (heroSparkLine && heroSparkArea) {
        const W = 360, H = 70, POINTS = 24;
        let dataPoints = Array.from({ length: POINTS }, () => 35 + Math.random() * 25);

        const drawSparkline = () => {
            const step = W / (POINTS - 1);
            let path = '';
            dataPoints.forEach((val, i) => {
                const x = i * step;
                const y = H - (val / 70) * H;
                path += (i === 0 ? 'M' : 'L') + x.toFixed(1) + ',' + y.toFixed(1) + ' ';
            });
            heroSparkLine.setAttribute('d', path);
            heroSparkArea.setAttribute('d', path + `L${W},${H} L0,${H} Z`);
        };

        drawSparkline();

        setInterval(() => {
            dataPoints.shift();
            const last = dataPoints[dataPoints.length - 1];
            const next = Math.min(65, Math.max(20, last + (Math.random() - 0.5) * 18));
            dataPoints.push(next);
            drawSparkline();

            const speed = (130 + Math.random() * 28).toFixed(1);
            if (heroLiveSpeed) heroLiveSpeed.textContent = `${speed} MB/s`;
            if (task1Speed) task1Speed.textContent = `${(80 + Math.random() * 15).toFixed(1)} MB/s`;
        }, 800);
    }

    // 11. --- SCROLL BEHAVIOR & REVEALS ---
    const navHeader = document.getElementById('navHeader');
    const nav = document.getElementById('nav');
    const backToTop = document.getElementById('backToTop');
    const revealEls = document.querySelectorAll('.reveal');
    const sections = document.querySelectorAll('section[id]');
    const navLinks = document.querySelectorAll('.nav-link');

    window.addEventListener('scroll', () => {
        const scrollY = window.scrollY;
        if (navHeader) navHeader.classList.toggle('scrolled', scrollY > 20);
        if (nav) nav.classList.toggle('scrolled', scrollY > 20);
        if (backToTop) backToTop.classList.toggle('visible', scrollY > 400);

        // Scrollspy for active nav link
        let currentSection = '';
        sections.forEach(sec => {
            const top = sec.offsetTop - 120;
            const height = sec.offsetHeight;
            if (scrollY >= top && scrollY < top + height) {
                currentSection = sec.getAttribute('id');
            }
        });

        if (currentSection) {
            navLinks.forEach(link => {
                const href = link.getAttribute('href');
                link.classList.toggle('active', href === `#${currentSection}`);
            });
        }
    }, { passive: true });

    if (backToTop) {
        backToTop.addEventListener('click', () => {
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });
    }

    if ('IntersectionObserver' in window) {
        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                    observer.unobserve(entry.target);
                }
            });
        }, { threshold: 0.1 });

        revealEls.forEach(el => observer.observe(el));
    } else {
        revealEls.forEach(el => el.classList.add('visible'));
    }

    // Initialize OS detection
    detectUserOS();
});