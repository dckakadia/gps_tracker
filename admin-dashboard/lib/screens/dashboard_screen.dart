import 'package:flutter/material.dart';
import 'map_screen.dart';
import 'users_screen.dart';
import 'backup_screen.dart';
import 'history_screen.dart';
import 'attendance_screen.dart';
import 'geofence_screen.dart';
import 'app_management_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String token;
  final int initialIndex;
  const DashboardScreen({required this.token, this.initialIndex = 1});

  @override
  _DashboardScreenState createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  static const _primaryBlue = Color(0xFF1565C0);
  static const _accent = Color(0xFF1976D2);

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
  }

  static const _navItems = [
    _NavItem(Icons.people_alt_outlined, Icons.people_alt, 'Users'),
    _NavItem(Icons.map_outlined, Icons.map, 'Live Map'),
    _NavItem(Icons.history, Icons.history, 'History'),
    _NavItem(Icons.today_outlined, Icons.today, 'Attendance'),
    _NavItem(Icons.fence_outlined, Icons.fence, 'Geofences'),
    _NavItem(Icons.backup_outlined, Icons.backup, 'Backup'),
    _NavItem(Icons.phone_android_outlined, Icons.phone_android, 'App'),
  ];

  List<Widget> get _screens => [
    UsersScreen(token: widget.token),
    MapScreen(token: widget.token),
    HistoryScreen(token: widget.token),
    AttendanceScreen(token: widget.token),
    GeofenceScreen(token: widget.token),
    BackupScreen(token: widget.token),
    AppManagementScreen(token: widget.token),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 700;

        return Scaffold(
          backgroundColor: const Color(0xFFF5F7FA),
          appBar: _buildAppBar(),
          body: SafeArea(
            child: isWide
                ? Row(
                    children: [
                      _buildNavRail(),
                      const VerticalDivider(width: 1),
                      Expanded(child: _screens[_selectedIndex]),
                    ],
                  )
                : _screens[_selectedIndex],
          ),
          bottomNavigationBar: isWide ? null : _buildBottomNav(),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 1,
      backgroundColor: _primaryBlue,
      foregroundColor: Colors.white,
      title: Row(
        children: [
          const Icon(Icons.location_on, size: 22, color: Colors.white),
          const SizedBox(width: 8),
          const Text(
            'GPS Tracker Admin',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, letterSpacing: 0.3),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('v1.0.1', style: TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
      actions: [
        _AppBarAction(
          icon: Icons.phone_android_outlined,
          tooltip: 'App Management',
          selected: _selectedIndex == 6,
          onTap: () => setState(() => _selectedIndex = 6),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.logout_rounded),
          tooltip: 'Logout',
          onPressed: _confirmLogout,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildNavRail() {
    return NavigationRail(
      backgroundColor: Colors.white,
      selectedIndex: _selectedIndex,
      onDestinationSelected: (i) => setState(() => _selectedIndex = i),
      labelType: NavigationRailLabelType.all,
      minWidth: 80,
      selectedIconTheme: const IconThemeData(color: _accent),
      unselectedIconTheme: IconThemeData(color: Colors.grey[500]),
      selectedLabelTextStyle: const TextStyle(color: _accent, fontWeight: FontWeight.w600, fontSize: 11),
      unselectedLabelTextStyle: TextStyle(color: Colors.grey[500], fontSize: 11),
      destinations: _navItems
          .map((item) => NavigationRailDestination(
                icon: Icon(item.icon),
                selectedIcon: Icon(item.selectedIcon),
                label: Text(item.label),
              ))
          .toList(),
    );
  }

  Widget _buildBottomNav() {
    return Theme(
      data: Theme.of(context).copyWith(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        selectedItemColor: _accent,
        unselectedItemColor: Colors.grey[500],
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 10),
        unselectedLabelStyle: const TextStyle(fontSize: 10),
        backgroundColor: Colors.white,
        elevation: 8,
        onTap: (i) => setState(() => _selectedIndex = i),
        items: _navItems
            .map((item) => BottomNavigationBarItem(
                  icon: Icon(item.icon),
                  activeIcon: Icon(item.selectedIcon),
                  label: item.label,
                ))
            .toList(),
      ),
    );
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: Colors.red),
            SizedBox(width: 10),
            Text('Logout', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red[600],
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
            },
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavItem(this.icon, this.selectedIcon, this.label);
}

class _AppBarAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  const _AppBarAction({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon),
        onPressed: onTap,
        style: selected
            ? IconButton.styleFrom(backgroundColor: Colors.white.withOpacity(0.2))
            : null,
      ),
    );
  }
}
