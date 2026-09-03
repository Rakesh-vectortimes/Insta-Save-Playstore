import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/constants.dart';
import '../core/responsive.dart';
import 'downloads_screen.dart';
import 'home_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  }

  @override
  Widget build(BuildContext context) {
    final useRail = AppBreakpoints.useNavigationRail(context);
    const pages = [
      HomeScreen(),
      DownloadsScreen(),
    ];

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: Row(
        children: [
          if (useRail)
            NavigationRail(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) {
                setState(() => _currentIndex = index);
              },
              backgroundColor: AppColors.darkBackground,
              indicatorColor: AppColors.darkCard,
              selectedIconTheme: const IconThemeData(color: AppColors.accent),
              unselectedIconTheme:
                  const IconThemeData(color: AppColors.textSecondary),
              selectedLabelTextStyle: GoogleFonts.poppins(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
              unselectedLabelTextStyle: GoogleFonts.poppins(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: Text('Home'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download_rounded),
                  label: Text('Downloads'),
                ),
              ],
            ),
          if (useRail)
            const VerticalDivider(
              width: 1,
              thickness: 0.5,
              color: AppColors.darkBorder,
            ),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: pages,
            ),
          ),
        ],
      ),
      bottomNavigationBar: useRail
          ? null
          : Container(
              decoration: const BoxDecoration(
                color: AppColors.darkBackground,
                border: Border(
                  top: BorderSide(color: AppColors.darkBorder, width: 0.5),
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: _NavItem(
                          icon: Icons.home_rounded,
                          label: 'Home',
                          selected: _currentIndex == 0,
                          onTap: () => setState(() => _currentIndex = 0),
                        ),
                      ),
                      Expanded(
                        child: _NavItem(
                          icon: Icons.download_rounded,
                          label: 'Downloads',
                          selected: _currentIndex == 1,
                          onTap: () => setState(() => _currentIndex = 1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: color,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
